# 0403. Seal the Optcarrot benchmark for closed-world compilation

Date: 2026-10-11

## Status

Accepted

## Context

The Optcarrot diagnostic runs a fixed benchmark, but its full-core mruby
executable can evaluate Ruby and load arbitrary script files. That executable
cannot satisfy bc2cpp's strict closed-world assumptions.

## Decision

Provide an opt-in `optcarrot-probe` world with a dedicated benchmark gem and
native host. Its complete generated bundle, including compatibility shims and
the interpreted benchmark runner, must be supplied as compiler input. The host
initializes fixed gem bytecode and invokes the benchmark; it does not load
source or bytecode files. Its arguments are benchmark data, not programs.

Reject the existing open-world gems and mruby-compiler. Scan the actual gem
manifest's native sources and all Ruby outside compiler input. Keep the existing
PSP, Wio and Maix validation unchanged. The compiled benchmark Ruby is excluded
from outside definitions only after validating its presence in compiler input.

The OnigRegexp gem installs four aliases through a literal symbol-array loop.
Its outside-source scanner conservatively rejects computed alias names. Copy
that gem into the temporary build and expand only the exact upstream loop into
literal conditional and unconditional aliases in the same order. Both the
runtime and analyzer use this copy. Reject upstream loop changes rather than
broadening the scanner or suppressing its refusal. The original gem stays
unchanged; alias behavior is compared with and without preexisting methods.

## Consequences

Closed-world proofs can see every benchmark method, including methods that stay
interpreted. Arbitrary upstream CPU/PPU generated-code options require an open
runtime and are unavailable in the sealed benchmark. This mode remains an
experiment: enabling the world does not guarantee that every individual proof
succeeds or that FPS improves.

The first combined 180-frame run returned checksum `59662` on CRuby, the
interpreter and the sealed executable, but installed only 17 compiled methods
and took 24.20 seconds. Sound Fiber reachability follows native callbacks and
by-name constructors into Config parsing, unused CPU wrappers, input events
and code builders. These computed sends broaden the graph and conservatively
refuse CPU hot methods. Improving this result requires receiver or native
callback provenance; the benchmark does not disable the safety analysis to
recover performance. Static dispatch without strict mode remains the faster
experiment.
