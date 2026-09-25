# 0231: Prove module-body ivar classes for singleton loop receivers

Date: 2026-09-24

## Status

Accepted

## Context

bc2cpp already had an inlined `Array#each_index` path, but `ClassLayout` only
analyzed method ireps. `RGSS::Input` initializes its four input arrays in the
module body, so its two hot `each_index` blocks retained standalone cfunc/RProc
fallbacks even though the receiver facts were provable. Treating every class
body as a singleton-body fact would be unsound: a class singleton method can
be inherited by a subclass, whose class object need not have the parent class's
ivars.

## Decision

Record the direct module-body irep labels associated with each module's
singleton owner and include them in both stratified `ClassLayout` passes. The
existing `trace_new_target` proof then recognizes the module body's
`Array.new(...)` assignments and the existing `Array#each_index` emitter removes
their dynamic block calls. Class bodies and `class << module` bodies are
intentionally excluded: they write ivars on a different receiver object.

## Consequences

The real RGSS compiler output inlines the two `RGSS::Input#update` index loops.
The whole-world coverage report falls from 355 to 353 cfunc/RProc block
fallbacks. The new `scripts/bc2cpp_module_body_ivar_check.rb` covers the module
path and both class/singleton-class negative cases. No class-body behavior is
changed; a class singleton loop still uses its existing fallback.
