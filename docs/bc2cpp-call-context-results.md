# Call-context receiver results

The compiler can analyze a selected user method with the exact receiver and
positional argument classes of one call. For example, `relay.carry(a).tag`
retains `a`'s class when `carry(value)` returns `value`, even if another call
passes a different class to the same method. `object.identity.next_method`
retains the actual receiver class, including a subclass inheriting `identity`.

Method flow also seeds lexical self for a declared leaf instance class whose
bytecode body has one owner. This lets implicit helper calls select their own
method bodies. Modules, shared bytecode and nested closures receive no lexical-self assumption.
[User receiver unions](bc2cpp-user-receiver-unions.md) extend this analysis to
small enumerable subclass families; with that extension disabled, parents with
subclasses receive no lexical-self assumption.

Call-input analysis requires an exact receiver and stable closed-world lookup, a
valid positional arity, and no nested ireps. Required, optional, rest and
trailing positional arguments follow [strict argument binding](bc2cpp-context-arguments.md).
Keyword, block and unknown argument shapes keep the existing analysis. The body is
analyzed over its control-flow graph; mixed, nilable and unknown returns cannot
justify an exact call. Recursive active contexts supply no assumption.

Argument masks belong to the local analysis and its cache key. They do not
narrow the method's global argument pools or change emitted method bodies.

Set `BC2CPP_CALL_CONTEXT_RESULTS=0` to disable this extension. Run
`scripts/bc2cpp_call_context_results_check.rb` with `MRBC` and a full-core mruby
build for generated-code and runtime parity checks. Its mutation check verifies
fourteen withdrawn conditions and an unchanged control.

See [ADR 0351](adr/0351-bc2cpp-call-context-receiver-results.md).

## Measured world

With identical Wio inputs on base `8b011eae`, disabling/enabling this extension
changes cached dispatch sites from 2,769 to 2,765. POLY stays 897 and compiled
entries stay 3,056. The reduction is in guarded fallback paths; these static
counts do not measure runtime hotness or speedup. The four removed fallback
arms are `x=`, `y=`, `width=` and `height=` in `RGSS::Window#initialize`.
