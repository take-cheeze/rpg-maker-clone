# 0407. Typed save setters, generated, written through the schema encoder

Date: 2026-10-12

## Status

Accepted. Builds on docs/adr/0400 (typed save readers). The on-disk format does not
change.

## Context

ADR 0400 left writing alone: `Game::State#to_lsd` stores each field through
`LCF::Array1D#[]=`, which encodes by the schema type. A future caller that wants a
checked, named write had only `rec[11] = value`, with the field named by a bare id
and a wrong-class value failing deep inside `LCF.encode` with no field in the message.

## Decision

`mruby-lcf/gen_save_typed_accessors.rb` now also writes `mrblib/save_typed_setters.rb`:
one `save_<field>=` per field of the same 17 tables (251), each a one-line
`save_put <id>, v`. The hand-written `mrblib/save_typed_put.rb` holds `Record#save_put`
and `SaveTyped.save_writable?`.

- **The schema encoder is the only encoder.** `save_put` checks the value's class
  against the field's schema type, then does `@rec[id] = value`, i.e.
  `LCF::Array1D#[]=` -> `LCF.encode`. There is no second encoder, so the bytes are
  those of the existing write by construction. `scripts/lcf_save_typed_check.rb` proves it
  for every field of every table (all 12 field kinds), and that a populated save read
  through the readers and written through the setters reproduces its bytes.
- **A wrong class raises `LCF::SaveTypeError`** naming the field
  (`Save.hero.through: expected bool, got Integer`) and writes nothing. An Integer is
  accepted for a `:double`; a typed record for a table; the named Hash a read of an
  ordered `:int16_array` returns is written back in schema order. `nil` drops the chunk
  (the field reads its schema default again).
- **Nested tables are written by value**, as `Array1D#[]=` already does: a nested
  table is stored as the bytes it had when assigned. A record returned by a parent's
  `table` reader is therefore linked to its parent (`Record#save_link`) and writes itself
  back up after each setter, so `typed.save_title.save_hero_name = 'x'` reaches the file.
  A nested `Array2D` (`rows`) is not linked: assign it again after editing rows.
- **No new by-name dispatch.** The generated file contains no String literal and no
  `send`/`define_method` (the check asserts this); the field's type and name are read
  from the record's schema inside `save_put`, so each setter carries only its id. Every
  new method name carries the `save_` prefix (`save_put`, `save_link`,
  `save_writable?`, `save_<field>=`), so none adds a candidate to a game method's
  dispatch in the bc2cpp registry. None of the classes is a bc2cpp owner, so no C++ is
  emitted for them.

## Consequences

- **Bytecode (host `mrbc`, no `-g`): the setter layer is 22,425 B (`save_typed_setters.rb`)
  plus 1,042 B (`save_typed_put.rb`) = 23.5 KB, over the ~8 KB an opt-in layer may cost
  on a flash-bound target.** It is therefore excluded on wio (`mruby-lcf/mrbgem.rake`,
  `spec.rbfiles -=`, the way the schema blob swap is wio-scoped). On wio the only cost
  is `Record#save_link` in `save_typed.rb`: 2,478 B -> 2,583 B (+105 B). Every other
  target compiles the setters.
- Nothing in the game calls the setters yet. `Game::State#to_lsd`'s call sites stay on
  `Array1D#[]=`: they run on wio, which does not ship the setters, and switching them
  would not remove a dynamic dispatch (the receiver is the same Array1D either way).
  The setters are for host tools and for the day a call site can be proven typed.
