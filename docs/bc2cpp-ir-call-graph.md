# Reporting call-graph argument types

The compiler already propagates class pools through unique-name calls. IR
reporting now carries complete receiver-specific argument facts through
polymorphic forwarding chains too. For example, when separate receiver classes
implement `entry(value)`, calls can prove one implementation receives
`Integer | Array`. That implementation can forward its value into another
polymorphic method whose argument then receives the same independent union.

Each round uses completed summaries from earlier rounds. A summary is published
only after all possible callers are covered; an unknown receiver, argument,
lookup target or opaque caller prevents the entire join. Excluding unrelated
same-name calls requires complete receiver sets and stable target lookup. Shared
body identities and nonmandatory arities are refused. Cycles without complete
independent seeds stay unknown. The analysis is capped at 8,192 parameter nodes
and 16 rounds, preserving completed facts if propagation stops at the round cap.

Parameter rows use source `inferred:call-graph`. The same argument summaries feed
independent IR return queries and RBS suggestions. Authored RBS bounds are never
used as independent graph seeds, and optimizer tables and dispatch are unchanged.
Use `BC2CPP_IR_CALL_GRAPH_TYPES=0` for a reporting comparison. See
[ADR 0446](adr/0446-bc2cpp-ir-call-graph-types.md).

On the current engine workload, this adds one required argument annotation
(555 to 556): `RPG2k::Scene::SkillMenu#move_teleport_cursor` receives Integer.
Typed returns and ivars remain 892 and 525. Existing class pools already cover
many simple graph cases; unknown receiver edges still limit further gains.
