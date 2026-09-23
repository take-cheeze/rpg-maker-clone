# 206. Embed-guard fallbacks on unsubclassed owners need no registration

Date: 2026-09-23

## Status

Accepted

## Context

docs/adr/0203 drops the `mrb_define_method` registration of a compiled
method once no runtime method-table lookup can reach its name, which lets
the compiler discard the method's `mrb_get_args` wrapper. Among the dynamic
references the proof counts is every string literal in generated C++.

When master started embedding more classes' ivars in their RData struct, the
eligible set shrank from 366 to 179. Embedding a class makes bc2cpp.rb
guard every direct call into it with MONO_EMBED_GUARD:

```cpp
if (bc2cpp_owner_class_N(M) == mrb_obj_class(M, recv)) {
  r5 = Owner_name_impl(M, recv, ...);
} else {
  r5 = mrb_funcall_id(M, recv, bc2cpp_sym(M, K), ...);  // by name
}
```

The fallback names the method, so its symbol-table literal made every
guarded name dynamic. All 113 `RPG2k::Scene::Map` names, which were
eligible before, dropped out this way.

## Decision

The fallback runs only when the receiver's class is not exactly the owner.
If nothing subclasses the owner, that receiver's class does not have the
owner in its ancestry. Its method lookup never reaches the owner's method
table: it finds the name on its own class or raises NoMethodError, whether
or not the owner registered it. So the fallback cannot need the owner's
registration.

`tools/bc2cpp/static_dispatch_registrations.rb` therefore stops counting a
generated file's symbol-table literal as dynamic when all of these hold:

- **Every** `bc2cpp_sym(M, K)` use of that entry is the `mrb_funcall_id`
  fallback of a MONO_EMBED_GUARD for that same method. Any other use keeps
  the name dynamic, as does any other literal spelling of it.
- The owner is a real class, not a `.singleton` pseudo-owner.
- Nothing subclasses the owner. This is decided conservatively:
  - every superclass in the closed world counts;
  - so does every constant path written after `<` or inside `Class.new(` in
    any scanned Ruby source (closed world, tests, `scripts/`, `.github/`,
    `tools/`). A written path may be relative, so an owner counts as
    subclassed when it equals the path or ends in `::` plus it;
  - any `Class.new(<non-constant>)` counts as subclassing every class;
  - in every native file that calls `mrb_define_class*`, every capitalized
    string literal counts too, since native code names a Ruby superclass by
    string.

Every other rule of docs/adr/0203 is unchanged, including the fixed-point
iteration. `scripts/bc2cpp_embed_guard_exemption_check.rb` (bc2cpp CI job)
pins each condition on a fixture, and `scripts/bc2cpp_static_dispatch_check.rb`
re-proves the whole list on every run.

## Result

The fixed point is 543 names, 364 more than docs/adr/0203's 179, and 280 more
hand-written `register.cxx` lines go. Only three engine classes are
subclassed today: `LCF::File`, `RPG2k::Scene::Base` and `RPG2k::Scene::Battle`.
The last one is why `RPG2k::Scene::Battle`'s guarded names stay registered:
an `RPG2k3::Scene::Battle` instance fails the exact-class check and really
does need them.

## Measurement

(pending: `wio_rgss_boot` A/B against docs/adr/0203's head)

## Consequences

- Runtime evidence: the `RPGMAKER_BC2CPP=1` SDL desktop build, with this
  list and the rescue, argc and accessor fixes, boots both test-bed games to
  the map. Its two battle runs fail with "undefined method '+' for NilClass",
  identically to a reference build of master plus only the rescue fix, with
  no registration dropped at all. That is the upstream regression
  docs/adr/0203 records, not this change.
- Residual risk is docs/adr/0203's, plus one more: a subclass created in a
  way no scan sees (`Class.new` reached through `send` or `eval` with a
  computed superclass, or a C extension outside this repository) whose
  instance then reaches a compiled caller. Nothing in this repository does
  that.
- Embedding and unregistration no longer pull against each other for
  unsubclassed classes. For a subclassed one they still do: a guard that
  accepted any `kind_of?` receiver without an override would recover
  `RPG2k::Scene::Battle`'s names too. That needs a bc2cpp.rb codegen change
  and is not part of this ADR.
