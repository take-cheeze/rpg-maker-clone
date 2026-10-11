# 0401. Specialize the Optcarrot benchmark's finite CPU dispatch

Date: 2026-10-11

## Status

Accepted

## Context

The CPU opcode table has 256 entries, but computed `send` calls hide both the
outer opcode target and nested addressing, instruction and store targets from
bc2cpp. Fixed positional arguments avoid interpreter allocations while keeping
this dispatch cost in the compiled hot loop.

## Decision

Provide `OPTCARROT_STATIC_DISPATCH=1` as a probe-specific source specialization.
Read the real upstream table under host Ruby, group equal entries into opcode
arms, and expand the small wrappers into their ordered named calls. Feed this
same transformation to the compiler and runtime bundle. Validate every table
entry and the exact upstream wrapper bodies, rejecting drift. Keep upstream
files unchanged and retain the dynamic baseline.

This is a fixed-benchmark transformation, not a generic inference for arbitrary
mutable dispatch tables. Runtime table mutation and wrapper replacement are
outside its contract. All 256 arms are compared against the upstream wrappers;
full frame checksums validate compiled emulation.

## Consequences

Three alternating 180-frame runs measured a compiled speedup of 1.84x (median
34.64 to 63.90 wall FPS), with checksum `59662` in all runs. The interpreter's
linear opcode case is slower, so the experiment remains opt-in.
