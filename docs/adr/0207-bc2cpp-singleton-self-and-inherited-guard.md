# 0207. bc2cpp devirtualizes singleton-method self calls and inherited methods

Date: 2026-09-23

## Status

Accepted

## Context

docs/adr/0200 traced the RPG2000 map scene (`scripts/rpg2k_scene_check.rb`,
52,309 `Scene::Map#update` frames) and listed the dynamic calls that were left.
Three of the causes looked fixable. We measured again on master at 3399f0c1,
using the same method: a CRuby `TracePoint` over the check, joined by
file:line:name to a copy of the generator that tags every instruction's C++
with its source line. A guarded site counts as dynamic only when the traced
receiver's class fails the guard. Calls per frame:

| cause | calls | main sites |
| --- | ---: | --- |
| implicit `self` in a module singleton method | 2.07 | `Game.camera_offset` calling `clamp` (game.rb:702), 2.04 |
| inherited method behind an exact-class guard | 1.26 | `db`/`term` on a `Scene::Base` subclass, `owner` on `RPG2k3::Scene::Battle` |
| call without keywords to a keyword method | 0.17 | `step_events` (map.rb:818), 0.13 |

All the marked dynamic sites together come to about 39 calls per frame. Most of
them are native RGSS methods, which need `mrb_funcall` anyway.

## Decision

**SINGLETON_LEXICAL_SELF.** LEXICAL_SELF now also covers an implicit-self call
inside `def self.x` (owner `X.singleton`). There `self` is `X`, provided `X`
is a module or a class that nothing subclasses. The call goes straight to that
singleton's own `_impl` when all of these hold:

- the singleton has exactly one irep definition of the name (a
  `module_function` copy has no irep, and two definitions would make the live
  one depend on load order);
- nothing is prepended to the singleton, and there is no unresolved mixin on
  it or on `X`;
- `X` is not `Object`, because a top-level `def self.x` belongs to `main` and
  is spelled the same way.

The singleton's own method table is searched first. `extend` and `include`
only add modules below it. `devirt_blocked_name?` and the emitted-text audit
still apply, as they do for LEXICAL_SELF. The attr-accessor half of
LEXICAL_SELF is not extended.

**INHERITED_GUARD.** In a POLY_SMALL_N chain, the branch for owner `T` also
accepts every closed-world strict subclass `S` whose lookup of the name must
end at `T`:

- no class from `S` up to (but not including) `T` has a registry definition
  of the name, includes or prepends anything, or has an unresolved mixin;
- nothing is prepended to `T`;
- the name is not in `symbol_installed_names` (`alias`, `alias_method`,
  `define_method`, `undef`, `remove_method`);
- no native definition of the name exists outside mruby's own core. Core
  natives only touch core classes and modules, which cannot sit between two
  closed-world classes that have no mixins. Without the native source map,
  any native definition of the name refuses;
- for an attr accessor, no class on the way embeds the ivar itself.

Each branch is capped at 16 subclasses. With subclasses present, the
receiver's class is read once into `bc2cpp_recv_class`. The `mrb_funcall`
fallback is kept. For a listed `S`, dynamic dispatch would run `T`'s own
method (its registered wrapper calls the same `_impl`), so the direct call is
the same code. This includes the embedded-ivar case: `S` does not embed, and
`T`'s initializer allocates the struct on both paths.

The keyword cause is left alone. It is 0.17 calls per frame, and a POLY
keyword call has no `mrb_funcall` form to fall back to.

## Consequences

- Traced calls per frame: implicit self 2.07 -> 0.00 and inherited guard
  1.26 -> 0.00. Marked dynamic calls go from 39.4 to 36.0 per frame.
- `scripts/bc2cpp_coverage_report.rb`: POLY-marked sites 3,232 -> 3,196. No
  other line changes.
- In the generated rpg2k gem, 40 sites become LEXICAL_SELF (36 POLY and 4
  POLY_SMALL_N, including 3 `clamp` sites). 233 POLY_SMALL_N chains gain
  subclass arms (`db` 95, `term` 74, `windowskin` 17, `parent` 15, ...), and 5
  do in lcf (`LCF::File#to_lcf`/`#terminate_root?` on its four subclasses).
  rgss changes only by owner-class cache slot renumbering.
- Explicit `Game.clamp(...)` calls (about 0.4 per frame) are still dynamic.
  A guard on the receiver's identity would cover them and is left as a
  follow-up.
- `scripts/bc2cpp_inherited_self_devirt_check.rb` (bc2cpp CI job) checks each
  refusal on fixtures. It also compiles a fixture against real mruby and
  checks that each call returns the interpreter's answer and that the
  devirtualized calls reach neither `mrb_funcall` nor `mrb_funcall_id`. It
  fails on the previous generator.
  `scripts/bc2cpp_embedded_ivar_access_check.rb` now reads the owner off the
  first compare of a hoisted guard.
