# 0294. bc2cpp: LCF_ROW_FLOW gives `db[...]`, table and row reads an exact class

Date: 2026-09-30

## Status

Accepted

## Context

ADR 0285 added the LCF schema as a data oracle (`LcfSchemaOracle`: the class `Array1D#[]` returns for
every schema field) and left it unwired: nothing proved that a receiver *is* an LCF row. The missing
link is a whole-program class flow `LCF::Database -> table (Array2D) -> row (Array1D)`.

The compiler already has one: `NumericFlow` (ADR 0276), a forward dataflow over class-set bitmasks whose
facts (pooled entry arguments, ivars by family, returns by name, constants, captured locals) are a least
fixpoint of may-sets, where `OTHER` means "unknown, never narrowed". A register typed only with some bits is
sound for *positive* claims because every source of the value is a modelled event. So the flow needs
three things: bits for the LCF object kinds, sources that produce them, and a transfer for `[]`.

The hard part is the *content* of containers. `tbl[i]` is a row only if nothing can put another object
in the table. A global "no `[]=` on anything that might be a table" gate is unprovable in this program
(receivers reach `[]=` through unknown classes), so the invariant is made true in the library instead.

## Decision

### Kinds (`tools/bc2cpp/lcf_row_flow.rb`)

`NumericFlow` bits 7 and up are object kinds, each "exactly an instance of":

- `FILE(klass)` for `LCF::Database`, `MapUnit`, `SaveData` (the `File` subclasses whose root is an Array1D;
  `lcf_schema_dump.rb --roots` reads which schema constant each one uses);
- `ROW(path)`: an `Array1D` over the elements at schema path `path` (`DATABASE`, `DATABASE/player`, ...);
- `TBL(path)`: an `Array2D` whose rows are `ROW(path)`. 185 kinds in all.

Transfers: `GETIDX`/`GETIDX0` on a receiver mask returns, per kind, `FILE[:x]`/`ROW[:x]` the class set of
the schema fact at `path/x` (`LcfSchemaOracle`: by `type`, plus the `default` class, plus nil when there is
no default), `ROW` in a table read is `ROW(path) | nil`, and `Klass.new` of a file class (`record_new_class`:
stable constant, standard constructor) is `FILE`. A key that is not a literal Symbol, an undeclared name, or a
receiver bit of any other class gives `OTHER`. A receiver with no value yet gives no value (not `OTHER`), as
the fixpoint must only grow. nil on the receiver contributes nothing where `numeric_nil_raises?('[]')`.

### Why the class of a read is fixed

- `Array1D#[]=` re-encodes any value to bytes (`LCF.encode`) and `#[]` decodes bytes by the field `type`;
  `@decoded` only caches decodes. A field read is therefore in the schema fact whatever was written.
- **`Array2D#[]=` now keeps only nil, bytes, or an `Array1D` over the table's own `elements`**
  (identity-preserving for the common case, re-read through the table schema otherwise). Before, it stored
  any object, so a table read could be anything; this is the one library change. Code that stored a row and
  kept mutating the original after storing a *foreign-schema* row sees the copy; none does in the engine
  (`mruby-rpg2k/mrblib/game/lsd_io.rb` fills each row before `tbl[i] = row`, over the same schema constant).
- `@root`, `@data`, `@decoded`, `@schema`, `@sym2idx` are written only by the methods that own them.

### Gate (`codegen_lcf_rows.rb`, `setup_lcf_rows`)

The proof is on only if: no global closed-world refusal; `Database`, `Array1D`, `Array2D` have no subclass
and no outside file touches them (`exact_class?`, `untouched_class?`), `LCF::File` is untouched, class
constants are stable, instances cannot gain singleton methods (`exact_instances_singleton_free?`), `new`
and `allocate` are standard; `File#[]`, `Array1D#[]`, `Array2D#[]`, `Array2D#[]=` are each defined once;
none of those five ivar names is written by name outside the compiler's view (reflection, native or foreign
spelling). The build prints `== LCF row flow ==` with `on` or `off: <reason>`.

### Consumers

- `compile_send`: a receiver whose mask is exactly one kind (or that kind plus nil, where nil only raises for
  the name) resolves by the registry alone (`lcf_exact_target`: superclass walk through untouched classes;
  `closed_world_exact_target` refuses any name spelled in a native source, which `[]` always is) and is
  called directly with no class guard and no `mrb_funcall` fallback. The nil case is one `mrb_nil_p` test
  whose arm raises with `bc2cpp_nomethod_named`.
- `static_indexable_class` returns the kind's class so `GETIDX` takes that path.
- Field results feed the existing numeric/array proofs (an `:int` field with a default is `INT`, so `+` on it
  loses its dynamic-send arm; an `Array` field feeds the loop recognisers).

## How receiver-is-row is proven, and what withdraws it

A register is a kind only if every value that can reach it comes from a modelled source: a `Database.new`, a
`[]` on a receiver already of a kind, or a fact (pooled argument of a method whose name is fully visible
with every call site enumerated, ivar family group, return join, constant, captured local) that is
itself only those. Any unmodelled path contributes `OTHER`, which poisons the fact for good: a row passed to
a method that another caller calls with a Hash, through `send(:name)` (a literal Symbol poisons the name), a
block parameter (`tbl.each { |id, row| }`), a `dup`/`clone` result, a value out of `Marshal`, an ivar with an
`attr_writer` or an untyped writer. Nil holes and absent chunks are in the class sets (`ROW | nil`). Replaced
rows (`tbl[i] = other`) cannot change the class (invariant above).

## Consequences

Measured on the wio closed world (`scripts/bc2cpp_coverage_report.rb`, shipped build; "master" is the same tree run with
`BC2CPP_LCF_ROW_FLOW=0`, which switches the proof off; the report prints both counts):

| | master | LCF_ROW_FLOW |
|---|---|---|
| untyped `GETIDX` sites behind the generic class gate (`bc2cpp_getidx(`) | 2,499 | 2,336 |
| exact-class `LCF_ROW_FLOW` direct calls | 0 | 165 (88 `Array1D#[]`, 63 `File#[]`, 12 `Array2D#[]`, 2 other) |
| cached `bc2cpp_send` sites | 10,184 | 10,181 |
| numeric facts: entry args / ivars / returns | 76 / 101 / 328 | 85 / 103 / 331 |
| arms whose send NUMERIC_OPERAND_PROOF removed | 353 | 354 |

The effect is deliberately modest and the cached-send count barely moves because an untyped `GETIDX`
dispatches inside the shared `bc2cpp_getidx` helper, not at a cached site. What is proven reaches the
`@db`/`db` chains (`RPG2k`, `Scene::*`, `Game::Shop`, `Game::EnemyAi`) and what they read.

What blocks the rest (of ~2,900 `[]` sites whose receiver is not proven, from a per-site trace):

- **Parameters** (~850 sites, and ~420 chains below them). Most call sites pass something the flow types
  `OTHER` (engine objects such as `self`, `@state`, have no bit), which drops the pooled argument. Pooling
  admits single-definition, pure-mandatory-arity methods only. An experiment pooling multi-definition
  names added no site; pooling `initialize` through `new` sites added 16 (`Game::Shop`, `Game::EnemyAi`) and
  was dropped: 4 `new` sends inside mruby's own IO/Hash mrblib (implicit self, `new(*args)`) may build any
  class, so soundness needs either class attribution of core singleton methods or withdrawing all
  constructor pooling. `Game::Actor`, `Game::Actors`, `Game::Party` (`initialize` with optional
  arguments, a `rescue` in `Actors#[]`) stay `OTHER`, and so do the ~100 sites that read `@db` in them.
- **Methods with a `rescue`** have no `NumericFlow` states (handlers refuse), so their reads stay guarded.
- **Block parameters** of `Array2D#each`/`map` are not typed; a typed `each` would need its yield modelled.
- A typed `Array2D#each` or `size` on a proven table is possible (the exact receiver is known) but not done.

Residual risk: the model of `mruby-lcf` is pinned by `scripts/bc2cpp_lcf_row_flow_check.rb` (every field
of every DATABASE, MAP_UNIT and SAVE_DATA position read through the real reader, plus the `Array2D#[]=`
invariant) and by the gate's definition counts, not by reading bytecode: an edit that changes what `[]`
returns without changing those would need the check to catch it. `Marshal.load` of hostile data, as for every
ivar fact, is outside the model. Mutation of the schema constants themselves is not modelled (the engine
only reads them).
