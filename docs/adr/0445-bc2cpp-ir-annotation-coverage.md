# 0445. Richer IR annotation coverage without optimizer feedback

Date: 2026-10-14

## Status

Accepted

## Context

Reusing source-class proofs improves IR observations but leaves opaque/polymorphic
parameters, nullable ivars and element reads unknown. Existing RBS contracts also
lose receiver-relative self returns and runtime module lookup. Reporting needs
these facts without weakening exact dispatch or turning declarations into proof.

## Decision

Keep this extension in the reporting layer. Enumerate callers with the existing
exhaustive admission rules, partition them only with complete receiver sets and
stable actual dispatch, and join their complete argument classes per definition.
Feed those independent required-argument facts to IR and parameter rows.

Report previously untyped ivars from settled admitted family-wide class pools.
Reject guarded or incomplete pools and retain uninitialized nil, including reads
inside constructors. Do not infer a global field type from individual stores.

Allow IR queries to consume existing literal element proofs and conditional RBS
Array/Hash member bounds. Require every reaching receiver to carry element
metadata and require Integer array indices. Include absent-key/index nil and
retain all dependency provenance. Conditional results remain excluded from
independent suggestions and optimizer facts.

Resolve RBS self returns against receiver bounds and contracts through runtime
prepend/include/ancestor order. Stop at actual unsigned overrides and refuse
unknown/cyclic lookup paths. Keep optional/rest/keyword and overload selection
outside this extension. Provide separate reporting comparison switches.

## Consequences

More parameter and field annotations can be represented as unions and nullable
bounds; richer nominal call chains and element reads become explainable. Closed
world and mutation admission remain conservative, so unknown callers, escaping
containers, dynamic lookup and unsupported RBS shapes remain unknown. Reports
never feed new assumptions into generated dispatch. Tests cover both productive
facts and proof withdrawal, alongside output neutrality and RBS round trips.

With the original authored signatures held fixed, the engine report increases
required typed parameters from 546 to 555 and typed ivars from 485 to 525.
Typed returns remain 892. Commit 40 independently derived nominal union/boolean
bounds in `sig/bc2cpp/ir_nominal.rbs`; scalar/container hints remain available
in the report without introducing new compiler hint assumptions here.
