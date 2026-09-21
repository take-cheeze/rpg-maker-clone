# 0182. Embed ivars set only through guarded fixnum bitwise/modulo binops

Date: 2026-09-21

## Status

Accepted

## Context

`IvarLayout.trace_type` decides whether an ivar can be embedded as a raw C
field by walking each `SETIV` site backward to a small set of recognized,
provably-Fixnum/Symbol sources (literals, the `ADD`/`ADDI` opcodes, and
another already-embedded ivar). Any other opcode -- including a `SEND` for
`%`/`&`/`|`/`^` -- stops the trace at `UNKNOWN`, which poisons the whole
ivar (`IvarLayout.join` requires every site to agree). Register-masking
idioms like `@sp_addr = @sp_addr & 0x1f` or flag combination like
`@status = @status | bit` are common in bit-oriented code (NES PPU/APU
state) and were poisoned by this gap even though `compile_send` already has
a guarded, unconditionally-safe fast path for exactly these four operators:
`%`/`&`/`|`/`^` on two Fixnums always produce a Fixnum, with no overflow or
Bignum promotion (unlike `+`/`-`/`*`'s `mrb_num_add`/`_sub`/`_mul` or `<<`'s
own overflow fallback to Ruby dispatch).

## Decision

`trace_type` now recognizes a one-argument `SEND`/`SSEND` for `%`, `&`, `|`,
or `^` as a Fixnum source when both the receiver and the argument register
recursively trace to Fixnum (the same backward walk, not a runtime check)
and the whole-program registry proves the operator has exactly one
definition and it is native (`IvarLayout.native_only_mono?`, a registry-only
duplicate of `CodeGen#native_only_mono?`'s identical guarantee, kept
separate because that one reads CodeGen's own instance state). This is
stricter than the existing `ADD`/`ADDI` case, which trusts the opcode
unconditionally; requiring a full recursive proof on both operands avoids
adding a second, weaker soundness bar to the same file. `+`, `-`, `*`, and
`<<` are deliberately excluded (see Context).

## Consequences

Ivars whose every write is a chain of literals, already-embedded ivars, and
`%`/`&`/`|`/`^` now embed. The real project's own 3 compiled gems (RPG2k,
RGSS, LCF) show a byte-identical `scripts/bc2cpp_coverage_report.rb` before
and after -- no ivar there currently fits this exact shape. The standalone
Optcarrot bc2cpp probe (`tools/optcarrot_probe/`) gains 4 embedded ivars:
`Optcarrot::APU#@frame_divider`, `APU::Pulse#@step`, `APU::Triangle#@step`,
and `PPU#@sp_addr`; `PPU#@sp_addr` is a class already compiled and installed
for the probe's headless benchmark, re-verified there (180-frame checksum
`59662`, matching CRuby and interpreted mruby, unchanged). Most of
`Optcarrot::CPU`'s and `Optcarrot::PPU`'s own registers stay unembedded --
their remaining `SETIV` sites go through opcodes this pass still does not
model (`SUB`/`SUBI`/`MUL`, `GETIDX`, or a `SEND` to another method), a
follow-up rather than something this change attempts.
