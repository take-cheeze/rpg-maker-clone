# 0400. Save state is read through typed accessors, checked on load

Date: 2026-10-11

## Status

Accepted. Builds on docs/adr/0395 (the `.lsd` is the authoritative save) and
docs/adr/0399 (the `.lsd` is the only save format, wio included). The on-disk
format does not change.

## Context

`LCF::SaveData` (docs/adr/0009) reads a `Save<N>.lsd` lazily and untyped. Each
chunk is raw bytes until something asks for it, and every caller reads a field
through `save[104][11]`-style numeric ids. Nothing in the reader says what Ruby
class a field is, and nothing checks a field's bytes against its declared type
before the game runs on them. A malformed field surfaced as an exception deep in
`Game::State.from_lsd`, or not at all.

`Game::Interpreter#restore_call_stack` (mruby-rpg2k/mrblib/interpreter.rb) rebuilds
the call stack from frames read out of chunks 113/114. Those frames' values were
unproven: nothing established that a frame's commands were a command list, or that
its ids were integers, before the interpreter used them. That proof needs a
frame with a declared shape that is checked when the save is read.

## Decision

**Typed accessors, generated from the schema.** `mruby-lcf/gen_save_typed_accessors.rb`
walks `LCF::Schema::SAVE_DATA` and every table it reaches (17 tables, 251 fields)
and writes `mruby-lcf/mrblib/save_typed_accessors.rb`: one reader per field, each
returning the field's value as the Ruby class its schema type declares
(`:int`/`:uint8` Integer, `:bool` true/false, `:double` Float, `:string` String,
`:Array1D` `LCF::Array1D`, `:Array2D` `LCF::Array2D`, packed arrays Array). A nested
table returns its own typed record. The generator emits plain methods, not
`define_method`, because mrblib is compiled by bc2cpp as a closed world. A
`--check` mode and `scripts/lcf_save_typed_check.rb` fail when the committed file
is stale.

**Checked load boundary.** `mruby-lcf/mrblib/save_typed.rb` holds the hand-written
part: `LCF::SaveTyped.fits?` (the declared class per type), `LCF::SaveTyped.read`
(decode, then check the class; a decode failure is re-raised with the field's path),
`LCF::SaveTyped::Record` (the base the generated classes subclass), and the
frame reader. `LCF::SaveData#initialize` runs the whole tree through
`SaveTyped::Save#check!` when a save is read from a stream. A mismatch raises
`LCF::SaveTypeError` naming the field, e.g.
`Save.hero.through: invalid bool size: 2`.

`RPG2k#load_save_state` (mruby-rpg2k/mrblib/main.rb) already turns any exception
from a save read into `nil` plus a logged `save slot N unreadable: <reason>`. That
is the existing path for an unreadable save, and a save that fails the typed check
takes it unchanged. The slot is an empty slot; nothing is half-loaded.

**One documented exception: the execution-state stack of chunks 113/114.** A
genuine EasyRPG F9-debug save carries a stack whose bytes do not decode as the
schema (see `Game::State.read_event_exec_frames`). That save has always loaded, with
the affected event restarting, and it still does. `UNCHECKED` in the generator
leaves that one field out of the read-time check. `EventExecState#frames` still
reads it, typed, and raises on a malformed stack, which `read_event_exec_frames`
turns into "nothing to restore" and a logged line, as before.

**Frame shape.** `EventExecFrame#frame` returns the Hash that
`restore_call_stack` consumes:

```ruby
{ commands: Array<LCF::EventCommand>,  # SAVE_EVENT_EXEC_FRAME field 2, :event
  current_command: Integer,            # field 11, :int, default 0
  event_id: Integer,                   # field 12, :int, default 0
  triggered_by_decision_key: true|false } # field 13, :bool, default false
```

`restore_call_stack` is unchanged. Proving its `@list` use is a separate task; this
change makes the frames it receives typed and checked when the save is read.

**Writing is unchanged.** `Game::State#to_lsd` still stores each field through
`LCF::Array1D#[]=`, which already encodes by the schema type. There are no typed
setters. Round-trip tests show the writer reproduces a read save byte for byte.

## Consequences

- A save whose bytes do not match its declared type is an empty slot with the
  reason logged, not a crash and not a partial load. Every save read now decodes
  the whole tree once, not lazily on access; the cost is one pass over the save at
  load time.
- `lcf_file.rb`'s `SaveData#initialize` now depends on the generated file. Every
  CRuby script that loads `lcf_file.rb` and reads a save must also load
  `save_typed.rb` and `save_typed_accessors.rb` (21 scripts were updated).
  `scripts/rpg2k_save_load_check.rb` never loaded `lcf_file.rb` at all; it now does.
- **Flash on wio is a cost this change has not measured on a link.** The generated
  file compiles to about 28.6 KB of bytecode with the host `mrbc` (no `-g`), and
  `save_typed.rb` to about 2.4 KB. Both ship on every target. ADR 0128 once
  excluded `from_lsd` on wio for the flash budget, and ADR 0109 measured the link.
  A `env:wio_rgss_boot` link has to be run before this is considered safe. If it
  overflows, the fallback is to swap in a smaller generated file on wio only, the
  way ADR 0109 handles the schema blob, at the cost of the read-time check there.
- No genuine RPG_RT or EasyRPG `.lsd` is in the repository (nor reachable from
  `scripts/download/*`, which fetch games, not saves), so the read-time check was first
  exercised only on saves this engine writes. `scripts/rpg2k/lsd_adversarial_check.rb`
  now builds the unlike-ours cases from the LCF format itself: unknown chunks and
  fields, trailing data, padded BER numbers, a save with every schema field present,
  maximum-size tables, RPG2000- and RPG2003-shaped saves all load; a wrong-size field,
  a chunk running past the end of the file, an absurd chunk id and an empty or
  header-only file are an empty slot with the reason logged; and every truncation of a
  valid save plus 2,100 seeded corruptions yield a state or a logged empty slot, never
  a crash. It found two real defects, fixed with it: a chunk id read from the file
  indexes a Ruby Array, so an id of 2,000,000,000 died with `NoMemoryError` (not a
  `StandardError`, so the slot-load `rescue` did not see it) -- ids above
  `LCF::MAX_CHUNK_ID` (0xffff) are now refused; and a chunk whose declared length ran
  past the end of the file was read short, so a truncated save loaded with its last
  field silently garbled -- it is now refused as `truncated chunk`. A save with no hero
  or inventory record (cut on a chunk boundary) used to log `undefined method '[]' for
  nil`; `Game::State.from_lsd` now names the missing record. A genuine save with a field
  that does not decode as its schema type still shows as an empty slot; the logged
  reason is what to look at.
- The accessors cover read access only. A write still goes through the schema
  encoder, and a future setter layer would be a separate change.
