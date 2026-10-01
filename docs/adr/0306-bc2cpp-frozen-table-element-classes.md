# 0306. bc2cpp: element classes of frozen literal tables

Date: 2026-10-01

## Status

Accepted

## Context

ADR 0296 left element classes unbuilt: an Array or Hash is mutable and aliasable, its element class is the join of
every store through every alias, and bc2cpp has no points-to or escape analysis. ADR 0295 declined integer ranges
and argument pools; this ADR adds neither. It builds the one slice of element-class analysis where the alias problem
does not exist: a literal that is frozen in the same expression.

`[1, 2, 3].freeze` and `{ 8 => 0 }.freeze` have no writer after `freeze` (every mutator checks the frozen flag; the
check script drives 29 of them against real mruby), so the slots are what the literal stored. There are about 50 such
constants in the engine (`WALK_PATTERNS`, `DIR_ROW`, `TURN_RIGHT`, `ATTR_RATE_PCT` ...), read by about 120 sites.

## Decision

`tools/bc2cpp/frozen_tables.rb` + `codegen_frozen_tables.rb` (kill switch `BC2CPP_FROZEN_TABLES=0`):

- **Shapes.** A `SEND0 :freeze` whose receiver is, back to back (`ARRAY`/`HASH` at index i, the send at i+1, same
  register), a single `ARRAY`/`HASH` op is a table. Its shape is the container, the class set of each slot and, for a
  Hash, the literal Integer/Symbol keys. Slot sets come from the writing op alone through reaching definitions
  (`LOADI*` Integer, `LOADL` Float/Integer, `STRING`, `LOADNIL`, nested `ARRAY`/`HASH`/range literals, constants
  proven Integer), never from the flow, so they cannot depend on the fixpoint they feed. Anything else is OTHER.
- **Kinds.** Each distinct shape is one NumericFlow object kind (bits from `OBJECT_KIND_BASE + 256`, above the LCF
  kinds, ADR 0294), so it rides pooled constants, arguments, ivars and return values.
- **Reads.** `GETIDX`/`GETIDX0`: a literal index in range reads exactly that slot, out of range nil, a proven-Integer
  index any slot or nil, anything else OTHER (a Range returns an Array). Hash: a literal key present reads its slot
  (last wins), absent reads nil (a literal has no default), any other key value-or-nil. `first`/`last`/`sample` (no
  arguments) read the end/any slot, nil for an empty literal; `size`/`length` are Integer; `freeze` is the kind.
- **Exact receiver.** A register whose class set is only table kinds of one container is an exact Array/Hash for
  `index_exact_class` (INDEX_EXACT, ADR 0296) and the other exact-core arms.

Soundness conditions (all must hold, else no table or no read of that name is proven):

| condition | enforced by |
| --- | --- |
| closed world, no global refusal | `frozen_tables_refusal_reason` |
| no per-instance singleton can exist (`def t.[]`, `extend`, `singleton_class`) | `exact_instances_singleton_free?` |
| no installer with a computed name; `alias_method`/`define_method`/`undef` of the name | `symbol_installed_names` |
| mruby's native method is the one reached: no Ruby definition ahead of it on the chain (Array/Hash and their prepends; for `freeze` also Enumerable, Object, Kernel), no prepend or unknown mixin on the class | `frozen_table_name_refusal`, `builtin_class_send_safe?` |
| no foreign Ruby or outside native registration of the name on those classes (or on a class the scan cannot name) | `ForeignDefiners`, `NativeExpressionDevirt.scan_class_registrations` over NATIVE_SRCS and the world's outside sources |
| the constant's every definition is visible and tracked | the existing constant groups (ADR 0276): a second definition of the bare name that is not a table joins its kind and loses the proof |
| the literal is frozen before anything else can hold it | adjacency of the literal and its `freeze` |

`Marshal.load`, `instance_variable_set`, `send` and `dup` need no condition: they cannot change a frozen table, and a
copy is a different, unfrozen object whose `dup` result is OTHER. An ivar holding a table is still withdrawn by the
ivar pools' own rules.

## What is not covered

- Mutable Arrays/Hashes held in ivars or locals (the 117 `IVAR_ACCESSOR/ELEMENT` and 7 `ELEMENT` sites of ADR 0296).
  That needs an escape analysis of every `GETIV` result and every writer, and is the next slice if it is wanted.
- `each`/`map`/`min`/`max`/`at`/`fetch` on a table. `each` needs a block-parameter pool (the block is only reached from
  that call, with arity 1).
- Class bits (`Klass.new` elements) and the exact-class flow's own element reads (`ExactOracle` is untouched; the
  exact receiver comes from the numeric flow through `frozen_table_exact_class`).
- A table built by `ARYPUSH`/splat/`HASHADD`, or frozen later, or a `%w[]` of more than one op.
- `[a, b].max` with unknown `a`/`b`: element analysis of a temporary adds nothing, the elements are what is unknown.
- Native code that writes a frozen array behind the flag (none does in the project's natives; core mutators all call
  the modify check, see the check's 29 attempts).

## Consequences

Measured on the wio closed world with `scripts/bc2cpp_dynamic_site_census.rb`, same tree with and without
`BC2CPP_FROZEN_TABLES=0` (see the PR for the table): the delta is small and is removal, not relocation. Receivers of
only 49 shapes exist, and most table reads end in `INT|NIL` (a computed index can be out of range) so few arithmetic
sites qualify. Tests: `scripts/bc2cpp_frozen_tables_check.rb` (model, generated code with 17 hostile worlds, compiled
against interpreted on full-core, core-only and 32-bit `mrb_int` builds) and `scripts/bc2cpp_frozen_tables_mutation_check.rb`
(13 mutants).
