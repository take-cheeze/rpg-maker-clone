# 0285. bc2cpp: record-like Hash slots give unguarded per-key facts, and the LCF schema as a data oracle

Date: 2026-09-30

## Status

Accepted

## Context

After ADR 0270-0273 the largest source of sends with an unresolved receiver is a value read out of an
Array or a Hash: `indexed_result` receivers (58 sites in the wio build), `write_loadnil`, parts of
`get_ivar`/`incoming`, and the operands of guarded arithmetic. Reading the Ruby behind the 58
`indexed_result` sites (and 40 more `GETIDX` sites picked at random from the 1,424 whose literal
Symbol key spells an LCF field) gives three families:

1. **A record-like Hash in an ivar**, about 25 of the 58 and the only one that is a Hash of the
   engine's own: `Scene::Battle#@ui`, a 34-key literal (`phase:`, `foes:`, `allies:`, `skills:`,
   `events:`, `battle:`, ...) that the class and `main.rb` read as `@ui[:foes].each_with_index`,
   `@ui[:battle].step_action`, `@ui[:events].battle = ...`.
2. **LCF rows**: `it[:attribute_set]`, `a[:skills].each`, `anim[:timings].each`, `row[:enemy_groups]`.
   These are not Hashes: `LCF::Array1D`/`Array2D`/`Sections`, Ruby classes whose `[]` decodes bytes.
3. Everything else (`save[108]`, `ARCHIVE_DIRS[kind]`, a `Hash.new` cache, core mrblib).

The compiler has one unguarded route from a value to its class: a fresh `Klass.new` in the same method
(`exact_new_receiver_class`). Every other fact (`ClassLayout`, `ELEM_HINT`, annotations) is guarded
by a run-time `mrb_obj_class` check whose else arm is a dynamic send, so it cannot remove a cached
site. The question was which of these families can be given an unguarded fact.

## Decision

### RECORD_HASH_PROOF (`tools/bc2cpp/record_hash.rb`, `codegen_record_hash.rb`)

A **record slot** is an ivar *name* (`@ui`), analysed over the whole closed world, that satisfies:

- every `SETIV` stores nil or a `HASH` literal whose keys are all Symbol literals (no `HASHADD`/
  `HASHCAT`);
- every use of the Hash is `h[key]` (any key), `h[:lit] = v`, `h.delete(:lit)` or a branch on it.
  ALIAS_SCAN walks every path from each `GETIV` (and from each call of the slot's attr reader, and
  from each literal), tracking `MOVE` copies and locals that a nested block captures (`GETUPVAR`
  sites are alias sources of their own). `OP_SETIDX` overwrites its receiver register, a Hash is
  truthy (the falsy edge of a branch drops the tested alias), and a handler edge carries the
  pre-instruction state. Any other read of an alias register (argument, receiver of another
  send, `RETURN`, another `SETIV`, array element, ...) is an escape and refuses the slot.
  Unknown opcodes are treated as reading every register from their leading one up;
- no `attr_writer`/`attr_accessor` reaches the name (an `attr_reader` is allowed: its call sites are
  alias sources, and a Symbol spelling of the reader outside the `attr_*` arguments refuses),
  no computed installer, no outside native/foreign source spells it, and no reflection can name
  it (`instance_variable_get/set`, `remove_instance_variable`, `each_object`: a literal name refuses
  that ivar, a computed one refuses everything).

Then the Hash behind `@ui[:k]` is made by one of the literals and changed only by the listed stores,
so the class of a read is the join of the values stored under the key, plus `NilClass` when a literal
omits the key or a `delete` can remove it. A `Hash.new`/subclass/`merge!`/`compare_by_identity`/
`dup`/`clone`/`send`/`Marshal` use of the Hash is an escape; non-Symbol keys refuse the literal.

Two pieces of supporting machinery:

- **`through_handlers:` on `BytecodeIR#reaching_definitions`.** The query used to refuse inside a
  protected range or at a handler target, which excluded the one `rescue` method that reads `@ui`.
  With the option it crosses handler edges: an instruction that can raise contributes both the value
  it is entered with and the value it leaves.
- **Call-site key pooling (`RecordHash::KeyPool`).** `@ui[scroll_key] = scroll if scroll_key` writes
  through a keyword parameter. A parameter resolves to the Symbols its callers pass when the method
  has one bytecode definition, no outside source spells its name, no op other than a call or a `def`
  mentions it (so no `send(:name)`, `&:name`, `method(:name)`, alias), every site has exactly the
  mandatory positional count (so no trailing Hash can be read as keywords) and no splat (ENTRY_ARG_
  CALLSITE_PROOF's admission). A store under a provably non-Symbol key (`nil`) cannot touch a Symbol
  key and is ignored.

Every key carries two class sets. **strict** admits only literal classes and `Array/Hash/String.new`
on the untouched core constants; **trusted** additionally admits what `proven_array_source_scan`
proves (a block-carrying `map`/`select`/`reject`, ARRAY_RETURN_PROOF names). The trusted set is not
sound by name: `Game::State#map` and `Scene::Battle#map` are `attr_reader`s, so `x.map { }` returns an
ivar for those receivers. It exists to measure the ceiling; `BC2CPP_RECORD_HASH_TIER=trusted` turns it
on, the default is strict.

Consumers (both unguarded):

- `proven_array_source_scan` accepts a `GETIDX` that reads a record key whose set is exactly
  `{Array}`, which feeds the Array block recognizers (`each`, `map`, `each_with_index`, ...).
- `CodeGen#record_hash_exact_class`: when every writer of the key(s) is a heap literal or a fresh
  `Klass.new` under a stable standard constructor (`exact_new_receiver_class` at each writer) and the
  key is never nil, the receiver is as exact as a `Klass.new` in the same method. `compile_send`
  takes the existing `CLOSED_WORLD_EXACT_CLASS` route, and a MONO target that embeds ivars drops its
  `MONO_EMBED_GUARD` class check and the `mrb_funcall` else arm.

`scripts/bc2cpp_record_hash_check.rb` pins every accepted shape and every refusal above by reason,
the generated code, and interpreted-vs-compiled answers on real mruby (key reassigned to another
class, to nil, deleted).

### LCF_SCHEMA_ORACLE (`tools/bc2cpp/lcf_schema_oracle.rb`): data only, not wired

`mruby-lcf/mrblib/schema.rb` is a static table, and `LCF.to_rb` decodes bytes by the field `type`
whatever a writer stored, so the class of `Array1D#[]` is fixed by the schema: `:int` reads an Integer
in [-2^31, 2^31) (`read_ber` reinterprets the low 32 bits), `:bool` true/false, `:string` String,
`:int8_array` Array, `:Array1D` a row, ...; an absent chunk reads its `default` and nil when it has
none; `enums:` is documentation (`to_rb` never maps an Integer to a Symbol). The oracle loads the table
under CRuby in a subprocess (as `gen_schema_blob.rb` does) and returns one fact per (schema path,
field): 1,519 facts, 765 field names, 750 with a single type, 547 of those never nil.

It is **not** consulted by any pass. A field name types a read only if the receiver is an LCF row of a
known schema, and nothing proves that without a whole-program class flow:

- the receivers are Ruby objects (`Array1D`, `Array2D`, `Sections`, `File`), and `[]` has nine
  definitions (`Game::Switches`, `Game::Actors`, a bitmap cache, ...): `it[:type]` could be any of
  them, or a Hash;
- the schema of a row is a path (`db[:item][id]` is `DATABASE.item`), and `db` reaches the engine as
  an argument or `@db`. The binding needs the class of `@db` (`LCF::Database`, set once in `main.rb`,
  copied through several classes' initializers), and only annotations give it today, which are guarded;
- `Array2D#[]=` stores any object, so a row read through a table is not a row on its own.

Of the 1,424 engine `GETIDX` sites (of 3,011) whose literal key is an LCF field name, 1,336 have a
single-type name and 703 a never-nil one, but only 153 have a receiver chain that ends at `@db`/`db`
(139 ivar, 14 argument; 65 of them go through further keys); 524 index a parameter (`it`, `row`, `a`),
149 a method result, 80 another ivar. Of 40 of them read at random, about two thirds were LCF rows and a fifth were the
engine's own Hash records that reuse a schema name (`@ui[:events]`, `cmd[:attack]`, `entry[:damage]`,
`{ target:, hp:, mp: }`). A name alone is wrong for those.

## Consequences

Measured on the wio closed world (`scripts/bc2cpp_coverage_report.rb`, shipped build):

| | cached `bc2cpp_send`/`mrb_funcall_with_block` sites |
|---|---|
| master | 10,954 |
| strict tier (default) | 10,927 |
| trusted tier (`BC2CPP_RECORD_HASH_TIER=trusted`, not sound by name) | 10,920 |

The 27 strict sites are `@ui[:battle]`/`[:events]`/`[:troop]` receivers that were guarded MONO calls
and are now unguarded exact-class calls (`CLOSED_WORLD_EXACT_CLASS` 2 to 36, of which 34 go through a
record key; `MONO_EMBED_GUARD` 1,088 to 1,061). Their by-name NoMethodError fallbacks left
`NOMETHOD_REVIEWED` (33 entries, all `Scene::Battle`). No `FIXNUM_ARITHMETIC`/`FIXNUM_COMPARE` arm moved: the record keys that hold numbers
are written by arithmetic on other reads, which no unguarded pass proves. The Array recognizers gain
nothing under the strict tier: the Array-valued keys of `@ui` (`foes`, `allies`, `skills`, `items`)
are all assigned from method results (`troop.members.map { }`, `@state.party.battle_items`), whose
class is exactly what the compiler cannot prove.

Of 57 ivar names with a Hash literal store, 4 are accepted and 53 refused. `@ui` is the one with
Symbol keys of consequence (51 keys, 285 reads, 153 stores); `@inn_window` has two keys with an
unclassified class each, and two maps keyed by non-Symbols carry no key facts. The refusals are mostly
right: 20 write under a key no caller pool resolves, 9 have an `attr_writer`, 6 have a reader named as
a Symbol, 11 pass the Hash on or return it, 6 store something that is not a literal, 1 is reached by
`instance_variable_set` and 1 by an installer outside the registry.

Limits, not fixed here:

- Values reach a key through method returns. A whole-program return-class join by name (sound only
  where every definition of the name is visible) would lift most Array keys and the numeric keys; it
  is the same proof ADR 0276's `NUMERIC_RETURN_PROOF` uses and is a separate change.
- `Marshal.load` of hostile data can allocate an owner with any `@ui`; it is outside the model, as for
  every ivar fact. A Marshal round trip of the *owner* preserves the facts, a `Marshal.dump(@ui)`
  is refused.
- A constructor whose last expression is the literal (`def initialize; @h = {...}; end`) returns the
  Hash and is refused; `Class#new` discards it but a direct `initialize` call does not.
- `key?`, `fetch`, `each` and every other Hash method refuse the slot; `delete(:lit)` is the only
  mutator modelled.
- The oracle needs a receiver binding before it can type anything. The natural next step is a
  whole-program object-class flow (ivar/argument/return sets, the shape of ADR 0276's numeric flow)
  that tracks `LCF::Database`, `Array2D(table)`, `Array1D(row of DATABASE.item)`; the oracle then
  answers the field read.
