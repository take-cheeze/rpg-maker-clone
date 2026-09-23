# 0203. bc2cpp: canonicalize bare class names that have one definition

Date: 2026-09-23

## Status

Accepted

## Context

`trace_new_target` records the constant a `.new` receiver names. A bare
single-token name is only qualified when `lexically_resolve_construct_target`
finds it in `DIRECT_CONSTRUCT_TARGETS`. Otherwise the written name is kept.
`Bitmap.new` inside `RPG2k::Scene::Map` is recorded as `Bitmap`. That string
names no registry owner, so ADR 0199's `@chipset_bmp`, `@windowskin` and
`@skin` hints and every older `Bitmap`/`Sprite`/`Viewport` hint (74 in all)
could not drive a TYPED, ELEMENT or IVAR_ACCESSOR call. `Weather`,
`Variables`, `Actors` and `Rng` inside `module Game` had the same problem.

At runtime mruby resolves a bare constant in `mrb_vm_const_get`
(`3rd/mruby/src/variable.c:1373`). It looks in the cref's own table, then in
each enclosing class body's table (the last one is Object's), and then in the
cref's ancestors. `class Object; include RGSS; end`
(`mruby-rpg2k/mrblib/main.rb:1`) puts RGSS among Object's ancestors. RGSS's
table holds `Bitmap`, which `mruby-rgss/src/lib.cxx:7534` defines under
`m = mrb_define_module(M, "RGSS")` (`:7372`) and
`mruby-rgss/mrblib/lib.rb:611` reopens. So `Bitmap` in RPG2k code is
`RGSS::Bitmap`, and `Sprite` (`lib.cxx:7419`, `lib.rb:862`) and `Viewport`
(`lib.cxx:7396`, `lib.rb:1125`) resolve the same way. `Window` does not.
`class RPG2k; class Window` (`main.rb:26`) is found lexically first inside
RPG2k, while RGSS code gets `RGSS::Window` (`lib.rb:1019`).

## Decision

`UniqueClassNames.analyze` (`tools/bc2cpp/unique_class_names.rb`) maps a bare
name N to P::N. It uses the program that StableClassConstants and
INTEGER_CONSTANT_PROOF already analyze: the closed world plus NATIVE_SRCS and
FOREIGN_RUBY_SRCS. A name is admitted only when all of these hold:

- Every CLASS/MODULE statement for N opens the same P::N. The statement's
  outer register must be a LOADNIL or OCLASS, which excludes the compact
  `class A::N` form. A statement the namespace walk does not reach counts as
  a second, unknown definition.
- Every native constant binding that names N is
  `mrb_define_(class|module)_under(M, v, "N")`. `v` must be assigned only from
  `mrb_define_module(M, "P")` in the enclosing function, or it must be an
  `RClass*` parameter that every caller passes such a variable
  (`define_rect`).
- No segment of P::N is assigned with SETCONST/SETMCNST or defined by a
  foreign source.
- No source calls `const_set`, `remove_const` or `autoload`, and none defines
  `const_missing`.

Under these conditions P's table is the only table that ever holds N, so a
successful lookup of N returns P::N wherever it runs. `UniqueClassNames.resolve`
also requires P::N to be reachable from the site. Either P lexically encloses
the owner, or the closed world includes P into Object.

`trace_new_target` returns the canonical name at the bare GETCONST terminal.
The three construct-target callers pass `canonical: false`, because
`NATIVE_CONSTRUCT_TARGETS` and `DIRECT_CONSTRUCT_TARGETS` are keyed by the
written name.

## Consequences

The analysis admits 83 names. No CLASS_HINT is added or lost. The 41 `Bitmap`,
30 `Sprite` and 3 `Viewport` hints and 4 `Game::` hints now carry the real
class. HASH_ELEM_HINT rises from 10 to 13 (`@vehicle_bmps`,
`@picture_tone_cache` and `@vehicle_sprites`). `Window` stays unresolved,
because it has two definitions.

The RGSS hints change no generated code. Every call that RPG2k code makes on
these ivars is a native method, such as `x=`, `opacity=`, `bitmap=`,
`visible=`, `blt`, `dispose` or `equal?`. A native method needs a VM frame,
so it cannot be called directly. The Ruby-defined `RGSS::Sprite` getters are
never called on them. The `Game::` hints change 10 call sites in
`mruby-rpg2k-compiled`, and each one keeps its class guard and `mrb_funcall`
fallback. Four of them are on the per-frame map path:
`Scene::Map#draw_weather` (`w.type` twice, now IVAR_ACCESSOR) and
`#pages_changed?` (`va.dirty`, now IVAR_ACCESSOR, and `va.clear_dirty`, now
TYPED).

The analysis does not cover the other maker gems or runtime game scripts. In
an RPG2k run the other maker gems are never initialized
(`src/main.cxx:908`). In other runs, RGSS code finds P::N lexically before
it reaches rpgxp's `RPG::Sprite` or its top-level `Color = RGSS::Color`. Every
consumer of a hint still checks the receiver's class at runtime.

Resolving the scope-dependent `Window` would take a per-site lexical proof.
A measurement that mapped it to `RPG2k::Window` turned 85 setup-time calls
(`windowskin=`, `contents=`, `z=`) into TYPED calls. That is left for later
work. `scripts/bc2cpp_unique_class_names_check.rb` covers every admitted and
refused shape, and mutating any single guard makes the check fail.
