# 369. bc2cpp: identity arms for module singleton definers

Date: 2026-10-07

## Status

Accepted

## Context

A guard chain whose receiver class is unproven can close its else (a
`bc2cpp_nomethod` instead of a by-name send) only when `ClosedWorld#refusal`
clears every reason. For an unknown receiver one reason is `:singleton_definer`:
some definer of the name is a `.singleton` method, and a class or module object
is not an instance of any class the chain lists, so the else could be a real
dispatch. The census (docs/bc2cpp-dynamic-site-census.md) held 91 sites for it
on master `c973a581`; 80 are `width`/`height`, whose one singleton definer is
`RGSS::Graphics` (`class << self; attr_reader :width, :height`). Every other
definer is an instance method the chains already list.

## Decision

A singleton definer no longer refuses when it can be armed (SINGLETON_ARMS):

- `ClosedWorld#singleton_arm_modules(name)` returns the modules owning every
  `.singleton` definer of the name, or nil unless each is a declared module
  (not a class, so there is no class-side inheritance and no subclass object),
  with a stable constant identity and no `clone` sent anywhere (a `clone` is
  the one way to copy singleton methods, ADR 0259 `module_object_self?`).
- `CodeGen#singleton_arm_branches` emits, per module, an arm in front of the
  else: `mrb_type(r) == MRB_TT_MODULE && mrb_class_ptr(r) == <owner class of the
  module>`, whose body is `constant_object_send_code` (ADR 0259). That function
  already refuses a singleton chain with a mixin, a rebound name (`alias`,
  `undef`, runtime installers) and a body it cannot call directly, and the
  chain falls back to dispatch when it does.
- `refusal` and `unlisted_classes` take the armed modules and skip exactly
  those singleton owners; every other check is unchanged. The else is then the
  existing `bc2cpp_nomethod`, listed in NOMETHOD_REVIEWED like any other dead
  fallback, so it raises what dispatch would.

`BC2CPP_SINGLETON_ARMS=0` restores the by-name else. A HOT_ONLY build keeps it
(as for UNLISTED_CLASS_GUARDS: its list of reviewed sites is the full build's).

## Consequences

- Census, wio closed world, same tree before and after: `bc2cpp_send` sites in
  bodies 2,286 to 2,205 (-81: `width` 47, `height` 33, `transition` 1);
  `bc2cpp_nomethod` sites 4,460 to 4,541 (+81); `closed_world_kept:
  singleton_definer` 91 to 10. No helper gained a caller.
- `scripts/bc2cpp_singleton_arms_check.rb` (ruby-checks): generated code for the
  positive world, four withdrawals (a class object definer, a `clone`, a mixin
  on the singleton class, a runtime definer) and the switch, then the world on
  real mruby, interpreted against compiled, on the full-core and core-only
  builds, with the compiled arms making no dynamic dispatch.
- `bc2cpp_closed_world_check.rb`'s `CwHolder` expectation changed: a non-self
  receiver now gets the identity arm.
- The ten remaining `singleton_definer` sites name class (not module) objects or
  chains that fail `constant_object_send_code`; they keep dispatching.
