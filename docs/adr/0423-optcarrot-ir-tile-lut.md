# 0423. Lower the Optcarrot tile initializer from decoded bytecode IR

Date: 2026-10-13

## Status

Accepted

## Context

The existing tile-table optimization emits fixed Ruby pixel expressions.
bc2cpp compiles registered methods, not class-body initializers, and the probe
installs its main compiled methods after all class bodies run. Merely adding
a recognizer would therefore never optimize table startup. Native lowering
also bypasses dynamically replaceable Ruby operators and collection methods.

## Decision

Use an opt-in ordinary-host initializer scaffold that extracts the upstream
generator verbatim into a zero-argument singleton helper. Compile and prove
its entire decoded `BytecodeIR` tree against a canonical unoptimized fixture.
Emit native array construction only for exact matching operands, symbols,
pools, children, control flow and handler absence. Bootstrap this helper
before its constant assignment without installing other compiled methods early.

Capture trusted core method identities when the compiled gem initializes;
root captured Ruby procs so identities cannot be recycled. Before installation
and every native call, compare collection and arithmetic method identities.
Allow Integer bit indexing only through the unchanged bootstrap method or an
exact IREP match for the probe shim. Keep an alias of the original helper as
the fallback, and refuse a preexisting fallback name.

Generate base rows once and copy colors into independent rows for nonzero
attributes. Preserve transparency and ordinary mutable mruby Array behavior.
Keep all numeric intermediates within signed 32-bit range and root retained
tables across allocation while limiting the GC arena.

## Consequences

The optimization itself no longer depends on generated optimized Ruby;
source extraction remains necessary because class-body emission is unsupported.
An exact fixture match is conservative and deliberately refuses altered
generators. This experiment targets startup and does not claim faster steady
emulation. The interpreter executes the original extracted generator.
Sealed mode is refused until it supports the same early helper bootstrap.
The existing source optimization remains the default, and the new path has
a separate `irlut` build suffix and native full-table and fallback checks.

The bootstrap method snapshots belong to the probe's single mruby VM per
process. Embedding this helper in a process with multiple independent VMs
requires per-VM storage before this protocol can be reused.
