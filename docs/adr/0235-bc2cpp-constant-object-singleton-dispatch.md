# 0235. Direct dispatch for stable class and module constants

Date: 2026-09-28

## Status

Accepted

## Context

Explicit calls on class and module constants (for example `Game.clamp` and
`RGSS::Graphics.freeze`) have a statically named receiver, but the ordinary
instance-receiver tracer intentionally does not treat `GETCONST` as an object
instance class. These sites therefore remained by-name calls even in a closed
world. The existing stable-class-constant proof was also stricter than needed:
it answered whether instances have an enumerable exact class, while this
optimization needs only to know that a constant continues to name the same
class/module object.

## Decision

For a straight-line receiver-register trace, carry a class/module-object
identity through `MOVE` and qualified `GETMCNST` writes back to the base
`GETCONST`. Resolve the lexical constant path and require its identity to be
stable in the closed world. Reopening the object is allowed; any known constant
reassignment is not.
Then emit a direct C++ call only when the registry has one public singleton
definition for the name, the call's arity is exact, the method compiles cleanly,
and the singleton lookup is not affected by blocked names or mixins. Branches,
other register writers, ambiguous names, rebound constants and unproven method
lookup all retain dynamic dispatch.

Native-defined class and module constants can also be receiver facts when
`UniqueClassNames` proves their fully-qualified identity across native,
bytecode, and foreign Ruby sources. Bare names brought into scope through an
`Object` mixin use that same unique-name proof; this resolves calls such as
`Input.repeat?` to `RGSS::Input.singleton` without guessing which constant a
bare name reaches.

For explicit `module_function :name`, the registry retains the copied singleton
entry's source irep and owner separately, without changing the instance method's
owner or compiling it twice. The copy can call that source body directly only
when a bytecode scan proves the body never reads or forwards `self`; otherwise
the module object could be mistaken for an instance of the module. The copied
body is emitted from the module's gem only when its singleton owner is selected,
and hot-only mode must list the singleton copy to keep that shared irep.

The closed-world constant proof treats non-string class-analysis sentinels as
unknown. They must be refused before applying name/hierarchy operations; a
symbolic unknown used to escape into `String#include?` and raised during full
code generation.

For value-constant receiver hints, a constructed constant may copy the result
of `Klass.new` through plain `MOVE` instructions before `SETCONST`. The proof
follows only those copies and rejects any intervening write or other factory
method; `trace_new_target` separately proves the class expression.

## Consequences

The full closed-world Wio codegen produced **426 direct singleton calls** from
stable class/module constant receivers, including qualified constant paths
whose identity is carried through `GETMCNST` register writes and 96 calls
through the uniquely proven `Input` alias; **269** use safe `module_function`
copies. Extending the proof to native unique names reduced unresolved
`constant_lookup` receiver sites from 334 to 238. A
non-closed-world run does not enable this proof. The hot-only closed-world
build passes with no LCF or RGSS `bc2cpp_nomethod` sites and 426 reviewed sites
in RPG2K. The all-method
`NOMETHOD_REVIEWED` set is regenerated and checked against 3,070 sites / 2,213
keys; dead fallbacks remain runtime raises rather than omitted branches.

The fact is deliberately separate from exact instance-class reasoning:
constant identity says nothing about the classes of objects returned by a
method, and so this optimization applies only to the class/module object used
as the receiver. This remains a local straight-line register proof; joins,
branches and other writers are not treated as typed merges.
