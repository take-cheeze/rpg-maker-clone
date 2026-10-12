# 0405. Generate an ordinary Optcarrot PPU method before compilation

Date: 2026-10-12

## Status

Accepted

## Context

The benchmark's original PPU uses a Fiber and a resumable compiled main loop.
Upstream also provides a synchronous code generator, installed per instance
through runtime eval. The benchmark can expose that code to bc2cpp before
building, removing coroutine transitions and enabling batched pixel work.

## Decision

Add opt-in `OPTCARROT_STATIC_PPU=1`. Run upstream's generator on the host with
clock specialization, fast paths and batched pixels. Replace only the original
`Optcarrot::PPU#run` with an ordinary instance method, preserving its logging.
Prism selects the method's byte range; unchanged prefix and suffix retain the
rest of upstream code. Require the exact source and original entry contract.

Use the same transform in the bundle and compiler sources. No generated code
is checked in, and no eval or code generation is added to target execution.
Keep a separate compiled target and report whether PPU#run is actually installed.

## Consequences

The ordinary compiled host improves steady emulation. The interpreted mruby
version is slower, so this remains an explicit benchmark choice. This is a
source specialization for the fixed benchmark, not a general AST optimizer.

Removing Fiber roots exposes sealed-world calls to computed Config accessors
that the method registry does not model. Its unreviewed fallback gate rejects
the build. Reject this flag combination early rather than suppressing the gate
or claiming those calls are unreachable. Supporting it needs static accessor
definitions or sound registry support in a separate change.
