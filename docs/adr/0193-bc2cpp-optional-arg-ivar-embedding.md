# 193. Drop the redundant pure_mandatory_arity? gate on ivar embedding

Date: 2026-09-22

## Status

Accepted

## Context

`drop_unsafe_embeddings` (`tools/bc2cpp/bc2cpp.rb`) has refused real ivar-struct
embedding for any class whose own `#initialize` has an optional, rest,
keyword or block argument, ever since the mechanism existed. `docs/adr/0139`'s
own follow-up section named `Game::Picture` as blocked by exactly this, and
every registration-completeness ADR since (`0186`/`0188`/`0190`) repeated the
same finding for `RPG2k::Window` and others: "needs either refactoring those
`#initialize` signatures or teaching the embedder to handle optional-arg
constructors -- a real design change."

Investigated whether that design change is actually needed, rather than
assumed. The gate at `drop_unsafe_embeddings`'s own `#initialize` check was:

```ruby
next unless init && pure_mandatory_arity?(@ireps.fetch(init.irep)) && compiles_clean?(init.irep)
```

`compile_method`'s own `mrb_data_init` emission for an embedding class's
`#initialize` (the struct allocation every embedded GETIV/SETIV depends on)
turns out to already be **completely arity-independent**: it is written
unconditionally, gated only on `embedded_ivars && d.name == 'initialize'`, and
placed before argument boxing settles into any optional/keyword dispatch
logic and before the goto-threaded instruction loop begins. Confirmed against
real generated C++ for two classes at opposite extremes of the arity space --
`RPG2k::Window#initialize(x=0, y=0, width=0, height=0)` (`ENTER
0:4:0:0:0:0:0:0`, all four params optional) and `Game::Battle#initialize`
(mandatory + optional + keyword combined, `ENTER 2:8:0:0:3:0:0:0`) -- the
struct allocation sits before the real `switch (bc2cpp_given_opt) { ... }`
dispatch (`emit_optional_dispatch`) in both, so it runs exactly once on every
real path through `_impl`, regardless of which optional/keyword arguments the
caller actually supplied.

`pure_mandatory_arity?` here was already redundant with `compiles_clean?`,
which is both necessary AND sufficient on its own: `compiles_clean?` is a
real `compile_method` call checked for a `#error` marker, and `compile_method`
already refuses (with a `#error`) any arity shape it doesn't actually model.
A `#initialize` that compiles clean therefore already has a real,
struct-allocating `_impl` regardless of its arity -- `pure_mandatory_arity?`
was rejecting classes `compiles_clean?` would have accepted, not catching
anything `compiles_clean?` misses.

Checked for a real hazard rather than trusting the placement alone:

- Every OTHER `pure_mandatory_arity?` caller in this file (`POLY_SMALL_N`,
  `BLOCK_FALLBACK`'s own `mandatory_ok` gate, `SYM_DEVIRT`,
  `DIRECT_CONSTRUCT_TARGETS`, ...) needs it for an unrelated, real reason:
  they call a target's `_impl` **directly**, bypassing the entry wrapper that
  supplies the optional/keyword dispatch parameters -- orthogonal to
  embedding, and unaffected by loosening only `drop_unsafe_embeddings`'s own
  check.
- `SUPER`'s own codegen calls a target's `_impl` directly too, and relies on
  `SUPER_TARGETS` being a hand-vetted, pure-mandatory-only allowlist rather
  than checking arity itself -- a pre-existing, unrelated gap (not
  introduced or worsened here): none of the classes this change newly
  embeds are `super` targets or have subclasses in the closed world.
- `dup`/`clone` on any `MRB_TT_DATA` object (every embedding-candidate class)
  already copy nothing at all in this engine today -- `3rd/mruby/src/
  class.c`'s own `init_copy` has no `MRB_TT_DATA` case -- an existing,
  arity-independent mruby-level gap, not something this change touches.

## Decision

Drop the `pure_mandatory_arity?` conjunct:

```ruby
next unless init && compiles_clean?(init.irep)
```

`compiles_clean?` alone is now the ivar-embedding gate. The stale reasoning
above `drop_unsafe_embeddings` (which asserted optional-arg `#initialize`
"was never going to compile," predating `OPTIONAL_ARG_SUPPORT`/
`KEYWORD_ARG_SUPPORT` landing in this compiler) is corrected in place.

## What was verified

- A real whole-closed-world before/after regenerate-and-diff (this exact
  one-line change, nothing else): **10 more real classes** safely gain
  embedding -- `RPG2k::Window` (5 ivars), `Game::Battle` (10), `Game::Enemy`
  (17), `Game::Party` (4), `Game::TextReveal` (3), `RPG2k::Scene::Map` (24),
  `RPG2k::Scene::MapViewer`/`ChipsetEditor`/`EquipMenu`/`SkillMenu` (3-4
  each) -- **77 ivars total**, plus 19 newly synthesized `ATTR_STRUCT_DEVIRT`
  struct-field accessors. **Zero classes lose embedding, zero new `#error`
  markers anywhere in the program.**
- `scripts/bc2cpp_coverage_report.rb`: entry points 2343 -> 2362 (+19,
  exactly the new accessors), classes needing `MRB_SET_INSTANCE_TT` 24 -> 34
  (+10, exactly the classes above), coverage unchanged at 100.0%/0 `#error`.
  POLY dynamic-dispatch sites 3386 -> 3370 (-16, more devirtualization from
  the new struct-aware accessors).
- All 22 `scripts/bc2cpp_*_check.rb` static checks pass.
- A full, real `RPGMAKER_BC2CPP=1` desktop build (`cmake --build`, all three
  `-compiled` gems, `libmruby.a`, the linked `rpg_maker_clone` executable)
  compiles and links clean end to end.
- Run for real, not just compiled: `--rgss_effect_probe` under `xvfb-run`
  reports `ok` (every screen effect reaches the real display), and a
  `--rpg2k_new_game` boot against Nepheshel reaches the map scene cleanly --
  `RPG2k::Window` (used by essentially every UI element: menus, message
  boxes, the whole HUD) is now genuinely struct-embedded and the game runs
  correctly against it, not just compiles.

## Consequences

Closes the exact gap `docs/adr/0139` flagged and every registration-
completeness ADR since repeated as a real, open design question -- with no
design change at all, only a redundant, overly conservative check removed.
`Game::Picture` and the other optional-arg classes ADR 0139/0186 named are
still not embedded: they were never added to `BC2CPP_WIRED_EMBEDDINGS` in
the first place (a separate, mechanical gate this change doesn't touch) --
a real, smaller follow-up now that arity is no longer the blocker.
`RPG2k::Scene::Map` gaining real embedding (24 ivars, the main map scene) is
the highest-value single result here, on the exact hot path this whole
devirtualization series targets.
