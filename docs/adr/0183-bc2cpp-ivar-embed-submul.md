# 0183. Embed ivars set only through recursively-proven fixnum SUB/MUL

Date: 2026-09-21

## Status

Accepted

## Context

ADR 0182 extended `IvarLayout.trace_type` to recognize `%`/`&`/`|`/`^`
sends as Fixnum sources. The `SUB`/`SUBI`/`MUL` bytecode opcodes (the
dedicated VM fast-path instructions for `-`/`*`, distinct from generic
`SEND`) were still unrecognized, even though the neighboring `ADD`/`ADDI`
case already trusts its own opcode unconditionally. The common
`@counter -= 1` / `@frames -= 1` countdown idiom (frame timers, turn
counters -- pervasive in this project's own `Game::*`/`RPG2k::Scene::*`
classes, and in Optcarrot's CPU registers) compiles to `SUB`/`SUBI` and was
poisoned to `UNKNOWN` by this gap.

Unlike `%`/`&`/`|`/`^`, `-`/`*` are not universally safe to trust from the
opcode alone: real mruby's `OP_SUB`/`OP_MUL` (`src/vm.c`'s `OP_MATH` macro)
dispatch on both operands' runtime types, and a Float operand produces a
Float result, not a Fixnum -- trusting the opcode the way `ADD`/`ADDI`
already does would be unsound here.

## Decision

Recognize `SUB`/`MUL` (both-register form) and `SUBI` (immediate form) as
Fixnum sources only when the operand register(s) are themselves recursively
proven Fixnum by the same backward `trace_type` walk. Once both operands
are proven Fixnum, `compile_insn`'s own generated fast path
(`mrb_fixnum_p(r_d) && mrb_fixnum_p(r_s)`) is unconditionally taken, so the
result is always Fixnum-tagged; a numeric overflow could still make the
*value* wrong (the same pre-existing, unguarded risk `ADD`/`ADDI`'s own
fast path already carries, and out of scope here), but the ivar's *type*
stays sound, which is all embedding needs. `ADD`/`ADDI`'s own existing,
narrower, unconditional-trust case is left untouched. `DIV` is excluded,
matching `compile_insn`'s own established precedent (it deliberately skips
the fixnum fast path for `DIV`'s rounding-direction reasons). As defense in
depth beyond this proof, an embedded ivar's generated `SETIV` write already
re-checks the runtime type and raises `TypeError` rather than corrupting
memory if a proof were ever wrong.

## Consequences

The real project's own 3 compiled gems gain 7 embedded ivars (all
frame/counter fixnum fields: `Game::Picture#@frames`,
`Game::Screen#@frames`/`@flash_frames`, `Game::Timer#@frames`,
`RPG2k::Scene::Map#@inn_choice`/`@player_route_timer`,
`RPG2k::Scene::Order#@counter`), `scripts/bc2cpp_coverage_report.rb`'s own
dynamic-dispatch count drops by 15 sites, and `#error` stays at 0 (no
coverage regression). The standalone Optcarrot bc2cpp probe
(`tools/optcarrot_probe/`) gains 6 more embedded ivars (`APU::DMC#@dma_
length_counter`/`@out_shifter`, `APU::Envelope#@volume`,
`APU::LengthCounter#@count`, `APU::Pulse#@sweep_count`, `PPU#@sp_limit`);
`PPU#@sp_limit` is in a class already compiled and installed there,
re-verified with the probe's 180-frame headless benchmark (checksum
`59662`, matching CRuby and interpreted mruby, unchanged). Most of
`Optcarrot::CPU`'s own registers still do not embed: their remaining
`SETIV` sites resolve through `@fetch[addr][addr]`/`@store[addr][addr,
value]`, NES's own memory-mapper dispatch (an Array of per-device
callables looked up by address, then called) -- a fundamentally different,
far larger devirtualization problem than an arithmetic-operand proof, not
something this change or ADR 0182 attempts.
