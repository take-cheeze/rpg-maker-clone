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
valid positional arity. Required, optional, rest and trailing positional arguments
follow [strict argument binding](bc2cpp-context-arguments.md). Keyword, block and
unknown argument shapes keep the existing analysis. Methods containing blocks
are admitted when all nested nonlocal returns can be conservatively modeled.
Block frames retain their own argument and self facts; caller masks are never
used as block arguments. Read-only captured locals use the defining context at
creation joined with all later parent stores, including through nested captures.
Captured registers written by a nested block remain unknown. A block `break`
changes the block-taking call result, so it does not change an unrelated method
return. The body is
analyzed over its control-flow graph; mixed, nilable and unknown returns cannot
justify an exact call. Recursive active contexts supply no assumption.

Argument masks belong to the local analysis and its cache key. They do not
narrow the method's global argument pools or change emitted method bodies.

Set `BC2CPP_CALL_CONTEXT_RESULTS=0` to disable this extension. Run
`scripts/bc2cpp_call_context_results_check.rb` with `MRBC` and a full-core mruby
build for generated-code and runtime parity checks. Its mutation check verifies
nineteen withdrawn conditions and an unchanged control, including captured
writes, nested nonlocal returns, later parent stores, capture context and the
block-analysis switch.

Set `BC2CPP_BLOCK_CONTEXT_RESULTS=0` to restore rejection of methods with
nested ireps while keeping the other call-context proofs enabled. See
[ADR 0353](adr/0353-bc2cpp-block-context-results.md).

See [ADR 0351](adr/0351-bc2cpp-call-context-receiver-results.md).

## Measured world

With identical Wio inputs on base `8b011eae`, disabling/enabling this extension
changes cached dispatch sites from 2,769 to 2,765. POLY stays 897 and compiled
entries stay 3,056. The reduction is in guarded fallback paths; these static
counts do not measure runtime hotness or speedup. The four removed fallback
arms are `x=`, `y=`, `width=` and `height=` in `RGSS::Window#initialize`.

With identical Wio inputs on base `c7e8cee8`, the block-context extension produces
byte-identical shipped C++ when enabled or disabled: 2,785 cached calls and 911
POLY sites. Its new receiver proofs are exercised by the focused fixtures; they
do not independently remove a fallback in that measured game build.
