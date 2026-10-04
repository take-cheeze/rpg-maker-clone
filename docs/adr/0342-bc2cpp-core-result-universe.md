# 0342. Core collection result classes independent of the receiver

Date: 2026-10-04

## Status

Accepted

## Context

ADR 0338 specializes core collection bytecode for a known exact receiver.
The actual bodies of Enumerable#filter_map and Enumerable/Hash#reject allocate
containers independently of self. Unknown input classes therefore need not
make their successful result classes unknown. A reject result can be Array or
Hash; the native expression emitter previously needed a single exact class to
remove its dispatch fallback.

## Decision

Analyze every retained core definition of an eligible zero-argument name with
unknown self and the actual supplied-block context, using ADR 0338's static
oracle. Join the actual bytecode return masks. Admit only container masks,
never a class inferred from the method name. Cache by name and block context;
the oracle reads no growing pool or Ruby return facts.

Require a complete closed world, singleton freedom, no linked native spelling,
no project or foreign Ruby definition, no installed/aliased name and no opaque
or omitted core definition. Require a dominating literal caller block with no
descendant break. Preserve the callee's nonlocal-exit and captured-write
exclusions. No call is bypassed: these facts describe successful returns only.

For an exhaustive exact core class mask, select an audited registered native
expression by type tag. Every class must have exactly one expression with the
actual call arity; the existing built-in lookup audit still applies. Nil,
unknown, other or uncovered class bits refuse the selection. The default arm
raises an invariant error rather than dispatching. A type tag selects a proven
class, so a separate class-pointer guard is unnecessary.

BC2CPP_CORE_RUBY_NAME_RESULTS=0 disables the new return join.
BC2CPP_NATIVE_EXPRESSION_UNIONS=0 disables the native selection. Both retain
the existing exact receiver proofs.

## Consequences

The existing core Ruby result harness exercises an unknown input, the joined
Array/Hash result, caller breaks, replacements, aliases, installers, omitted
core definitions, both switches and open worlds. Runtime comparisons keep the
original collection calls and compare interpreted and compiled behavior.
The same-tree Wio measurement on 7cad57bf (with the workspace's existing native
submodule changes) drops the coverage report's cached total from 2,781 to 2,776.
Generated method bodies lose five ordinary sends, all in RPG2k: 1,569 to 1,564.
RPG2k block calls remain 275; all-gem block calls remain 403 and other funcalls
remain 30. Two exhaustive native selections are emitted. No call is relocated
into a helper. Both switches off reproduce the parent shipped C++ byte for byte.
These static counts do not claim a runtime speed measurement.

Host compiled/interpreted parity, native expression checks, fifteen mutation
checks plus their control, and the reviewed-fallback audit pass. The latter
retains all 2,931 reviewed keys / 4,186 sites. The existing
CI int32 job runs the extended core result harness too; the new generated code
introduces no integer-width arithmetic or bignum conversions. Local CTest passed
six tests and failed four SDL display probes during renderer initialization;
SDL_RENDER_DRIVER=software retained the same failures.
