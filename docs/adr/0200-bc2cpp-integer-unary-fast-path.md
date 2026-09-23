# 0200. bc2cpp computes Integer `-x`, `zero?` and `round` inline

Date: 2026-09-23

## Status

Accepted

## Context

About 3,370 call sites in the generated C++ are `// POLY` dynamic dispatch. To
see which ones run every frame on the RPG2000 map scene, the map-scene check
(`scripts/rpg2k_scene_check.rb`, 52,309 `Scene::Map#update` frames over 1,062
scenarios) was run under a CRuby `TracePoint`. Each executed send was matched
to its generated site through a line-annotated copy of the generator. About 34
dynamic calls per frame are left. Grouped by cause (calls per frame):

| cause | calls | fix |
| --- | --- | --- |
| native C method on an RGSS Sprite/Viewport/Bitmap (`visible=`, `opacity=`, `update`, `fill_rect`, ...) | 14.5 | none: a cfunc needs a VM call frame, which is what `mrb_funcall` provides |
| native method taking a block (`Profiler.section`, `Hash#each`/`each_value` on a receiver with no proven class) | 8.9 | needs receiver-class facts or native semantics |
| core Numeric/Integer method on an untyped Integer (`round`, `zero?`) | 3.8 | this ADR |
| implicit `self` inside a module singleton method (`Game.camera_offset` calling `clamp`) | 2.0 | LEXICAL_SELF skips `.singleton` owners |
| other core natives (`Array.new`, `freeze`) | 1.2 | |
| inherited method behind an exact-class guard (`Scene::Base#db` on a subclass) | 1.0 | |
| stale `compiles_clean?` probe (`pages_changed?`, see Consequences) | 1.0 | |
| call without keywords to a keyword method (`step_events`) | 0.1 to 1 | |

The first two causes cannot be removed by devirtualization. The third is the
largest fixable one. Integer has no C method for `-@` or `zero?`. They are
Ruby methods in libmruby: Numeric#-@ is `0 - self` (`3rd/mruby/mrblib/numeric.rb`)
and Numeric#zero? is `self == 0` (mruby-numeric-ext). So each call goes through
`mrb_funcall` and runs the VM again. Integer#round with no argument is `int_round`,
which returns `self`.

## Decision

Add INTEGER_UNARY to `compile_send`. For `-@`, `zero?` and `round` with no
arguments, emit `if (mrb_integer_p(recv)) { ... } else { mrb_funcall }`:

- `-x` becomes `mrb_int_value(M, -v)` when `v != MRB_INT_MIN`. `-MRB_INT_MIN` is
  a bigint, so it keeps the dispatch.
- `x.zero?` becomes `v == 0`. OP_EQ compares two Integers directly.
- `x.round` returns `x`.

The fast path applies only when these conditions hold:

- The name is `native_only_mono?`: it has no Ruby definition anywhere in the
  closed world.
- `builtin_class_send_safe?` holds for Integer, Numeric, Comparable and every
  module the closed world includes or prepends into them, transitively. There
  must also be no unresolved mixin.
- The receiver has the exact `MRB_TT_INTEGER` tag at runtime.

An Integer cannot have a singleton class, so the exact tag leaves only those
ancestors. Every other receiver, a Float `@pan_x` included, still gets the
ordinary dispatch.

## Consequences

The number of `// POLY` sites drops from 3,370 to 3,268 (-102: 94 in
rpg2k, 8 in rgss). The 102 sites are 64 `-@`, 33 `zero?` and 5 `round`. On the
map path the four hottest sites are gone: `Game::Screen#pan_offset`'s two `round`
calls, which run every frame, and `Game::Interpreter#call_stack_snapshot`'s two
`zero?` calls. Dynamic calls in the trace drop from 34.0 to 30.3 per frame.
Nothing else in the coverage report changes.

Like TO_I_TYPE_TAG_DISPATCH, this trusts the pinned mruby sources for what the
replaced bodies do, and trusts that nothing outside the scanned sources reopens
Integer's ancestry. That includes a user RGSS script loaded at runtime.

`scripts/bc2cpp_runtime_devirt_check.rb` covers the emitted shape and checks
that a reopened `Integer#zero?` or an unresolved include into Integer keeps the
dispatch. It also runs the emitted code against a real mruby core on Integer,
`MRB_INT_MIN` and Float receivers and compares each result with the replaced
body.

Two causes found here are left for follow-ups:

- **Module singleton self.** Extending LEXICAL_SELF to module (not class)
  `.singleton` owners fixes `clamp`.
- **`compiles_clean?` state leak.** `compiles_clean?` re-enters `compile_method`
  while the caller's per-method state is still set (`@inline_nested`,
  `@block_fallback_active`, `@blk_param_name`, `@runtime_installed_names`, ...).
  The nested compile reads that state and clears it for the caller. A clean
  method can then be cached as unclean. `RPG2k::Scene::Map#pages_changed?` stays
  POLY that way, and 17 `Game::State` ivars miss embedding. Saving and resetting
  that state around the probe removes 16 more POLY sites.
