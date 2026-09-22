# 0196. bc2cpp exact-class guards treat an undefined class as "no match"

Date: 2026-09-22

## Status

Accepted

## Context

TYPED calls, POLY_SMALL_N chains, typed element guards and the Struct index
guard compare `mrb_obj_class(M, recv)` with an owner class resolved by
`bc2cpp_owner_class_N(M)` (ADR 0184). That helper resolved the owner with a
chained `mrb_const_get`, which raises `NameError` when any path segment is not
defined.

The three compiled gems are compiled as one closed world, so a POLY_SMALL_N
chain in `mruby-rgss-compiled` can name an RPG2k class. `RGSS.effect_probe`
calls `bitmap.width`, and the chain for `width` is RGSS::Sprite, RGSS::Window,
Game::Map, RPG2k::Window. In an RGSS-only run `Game` is never defined, so a
`RGSS::Bitmap` receiver fell past the two RGSS branches and the `Game::Map`
check raised `NameError: uninitialized constant Game`. Every
`RPGMAKER_BC2CPP=1` desktop build failed `--rgss_effect_probe` this way, and
an RGSS game hits the same chains. CI's `bc2cpp` job only builds
`libmruby.a` and runs the static checks, so the linked executable never ran.

## Decision

Resolve the owner path one segment at a time in a shared
`bc2cpp_owner_class_lookup`, checking `mrb_const_defined` before each
`mrb_const_get`. A missing segment returns `nullptr`, which never equals a
real object's class, so the guard is false and the call takes the chain's
existing dynamic-dispatch fallback. `nullptr` is not cached, so a class
defined later is still found on the next call.

Every caller of `owner_class_ptr_expr` is such an equality guard with a
fallback, so no caller relied on the `NameError`.
`emit_owner_registrations` keeps its raising `const_chain_value_expr`: a
wired owner that is missing at registration time is a real error.

## Consequences

The RGSS probe passes in a bc2cpp build. A guard naming an undefined class
does one `mrb_const_defined` per call it is reached on, instead of raising;
that path already ends in `mrb_funcall`. The resolved pointer for a defined
class is cached exactly as before. `mrb_const_defined` excludes the `Object`
fallback that `mrb_const_get` applies to a nested segment, which only matters
for an owner path that does not name a real nested class; generated owners
always do.

`scripts/bc2cpp_owner_class_cache_check.rb` now asserts that an undefined
class yields `nullptr` without raising and is not cached.
