# Contextual IR result reporting

IR feedback specializes Ruby callees using independently proven receiver and
argument classes. Required, optional and direct keyword arguments are bound to
their bytecode entry slots; supplied optional arguments select the matching
default-entry path. Recursive summaries converge before any result is published.
Unknown dispatch, splats, handlers and nonlocal block exits remain unknown.

Each graph is bounded to 512 contexts and 48 rounds. Exhausting either budget
withdraws the graph's provisional results. `BC2CPP_IR_CONTEXT_MAX_CONTEXTS` and
`BC2CPP_IR_CONTEXT_MAX_ROUNDS` can lower those limits for diagnostics.
`BC2CPP_IR_CONTEXT_RESULTS=0` disables contextual reporting.

Transitive read-only Ruby call summaries can preserve ivar facts across calls.
Fresh, frozen Array and Hash builders can carry element unions into indexing;
mutable or escaped builders are refused. Disable these bridges separately with
`BC2CPP_IR_EFFECT_SUMMARIES=0` and `BC2CPP_IR_CONTEXT_SHAPES=0`.

Audited native direct expressions expose boolean, numeric and receiver results
only after the existing native identity and class stability checks pass. The
JSON `native_direct_forms` inventory lists method/arity templates and refusal
reasons. This inventory measures supported forms, not runtime execution coverage.
`BC2CPP_IR_NATIVE_EXPRESSION_TYPES=0` disables this result bridge.

The current audit types 22 of 43 direct-expression forms: 13 boolean, five
Integer, and one each Array, Float, Hash and Symbol. On the engine workload,
the combined reporting extensions increase typed method returns from 892 to
904; typed required parameters remain 556 and typed ivars remain 525.

RBS feedback and suggestions retain optional positional and named keyword
contracts. Array element contracts also describe literal iterator block
arguments, with declaration provenance. These contracts never seed independent
contextual proofs. Reporting refinements do not change native dispatch or scalar
optimization hints. See [ADR 0447](adr/0447-bc2cpp-contextual-ir-results.md).
