# 0406. Bounded method inlining from bytecode IR

Date: 2026-10-12

## Status

Accepted

## Context

Upstream Optcarrot PPU source inlining creates a method that mrbc rejects with
`too big jump offset`. The existing synchronous core and its individual Ruby
helpers compile independently. Combining their instructions after decoding
avoids encoding a larger Ruby method in mruby's bytecode format.

## Decision

`BC2CPP_IR_INLINE=1` expands eligible direct calls to same-owner methods on
implicit self. `BytecodeIR::MethodInlineRegion` validates the decoded callee
and its resolved control-flow edges. The emitter traverses those IR nodes,
uses a separate lexical register namespace, snapshots arguments before
declaring registers and lowers returns into a result plus a symbolic exit.
The original IREP and its analysis caches remain unchanged. Callee facts and
literal pools are queried with the callee's original instruction index.

Existing dispatch resolution selects the target first. Inlining replaces
only its direct-call body; receiver checks and fallback arms remain in place.
Only mandatory positional arguments are admitted. Initializers, core methods,
blocks, handlers, upvars, unsupported opcodes, direct recursion and Fiber
unsafe bodies are refused. Resumable callers are refused. Bodies are limited
to 256 instructions and 128 registers, with two nested inline regions and
512 added instructions per compiled method. Nested compiler probes save and
restore that budget along with their other method state.
Native argument conversions retain their ordinary call boundary.

## Consequences

No source expansion or bytecode reserialization is needed. Expanded C++ can
span a distance beyond a 16-bit bytecode jump because labels are symbolic.
This first implementation preserves scoped callee facts; it does not merge
caller and callee dataflow or introduce whole-program inference assumptions.

Code size and C++ compilation time can grow. The feature is opt-in and uses
a distinct Optcarrot build target. State equivalence and native measurements
are required before claiming an optimization or changing defaults.
