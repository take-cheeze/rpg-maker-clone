# 0190. Close the mruby-rpg2k-compiled registration-completeness gap

Date: 2026-09-22

## Status

Accepted

## Context

`docs/adr/0188`'s own closing section found, auditing every
`mruby-rpg2k-compiled` owner's registration the same way `scripts/
bc2cpp_wired_embedding_check.rb` already does for wired owners: **402 of
2141** compiled, `#error`-free entry points across the whole gem were never
installed by any mechanism -- neither the hand-written `register.cxx` nor
bc2cpp's own generated `bc2cpp_register_owner_methods` (which only ever
covers `BC2CPP_WIRED_EMBEDDINGS`'s classes). These kept running the slower
interpreted bytecode despite real, `#error`-free compiled C++ already
existing for them, concentrated in the hottest classes in the engine:
`RPG2k::Scene::Map` (122 of 408 missing, including `#update`/`#render`/
`#draw_events`), `Game::Battle` (60 of 141, including `#step`),
`Game::Actor` (38 of 118), `Game::Party` (32 of 128) -- exactly the shape
`docs/adr/0186`'s own "Consequences" section had already named for
`Game::Actor` specifically as needing "that separate registration gap
closed too... not this file's own scope."

The fix mechanism already exists and needed no new code: adding a class to
`BC2CPP_WIRED_EMBEDDINGS` makes `emit_owner_registrations` install every
compiled entry point of that class unconditionally, by construction (see
that constant's own comment in `tools/bc2cpp/compiled_gems.rb`) --
`docs/adr/0188` already used this for `RPG2k::Window`. The real work this
round is the verification: `BC2CPP_WIRED_EMBEDDINGS` also gates real
ivar-struct embedding (`drop_unsafe_embeddings`), so each candidate owner
needs checking for whether wiring it would newly trigger embedding, and if
so, whether that embedding is sound.

## Decision

Triage every owner with a registration gap (four parallel investigations,
one per natural grouping -- Map; Battle/Actor; Party/misc data classes and
singletons; the smaller Scene menu classes -- each independently reading
the owner's real `#initialize` source and `attr_reader`/`writer`/`accessor`
declarations against bc2cpp.rb's own `pure_mandatory_arity?`/
`natively_exposed?`/`synthesizable_accessor_only?` gates), then confirm
every finding empirically against the real generated diagnostic and code
rather than trusting the manual read alone -- the same "measured, not
guessed" discipline this whole ADR series holds itself to.

Every owner's `#initialize` falls into one of three provably-safe shapes:

1. **Optional/rest/keyword arguments** (`RPG2k::Scene::Map`'s `apply_access:`
   keyword, `Game::Battle`'s mixed optional+keyword args, `Game::Party`'s
   `ids = nil, roster = nil`, `Game::Enemy`'s `x = 0, y = 0, hidden = false`,
   `Game::TextReveal`'s 5 optional args, and six `RPG2k::Scene::*` menu
   classes) -- `pure_mandatory_arity?` structurally refuses embedding
   regardless of wiring, so adding these has registration-completeness
   effect only, the exact `RPG2k::Window` precedent.
2. **Pure mandatory arity, zero raw-embeddable ivars today** (`RPG2k::Scene::
   Base` -- confirmed via the real diagnostic's own `== ivar embedding ==`
   section showing no `EMBED` line for it at all, only one still-opaque
   `CANDIDATE` for `@parent`; `RPG2k::Scene::Battle`, `RPG2k3::Scene::Battle`
   likewise) -- embedding is possible in principle but nothing currently
   proves, so wiring is registration-completeness in practice, and, since
   `Base` has no raw-embeddable ivar, none of its many subclasses can be
   blocked by bc2cpp's "one `DATA_PTR`, no ancestor-and-descendant both
   embedding" rule (`drop_unsafe_embeddings`'s own `inherited_layout` check
   keys off `IvarLayout`'s raw, wiring-independent result, not the wired
   set) -- confirmed directly for every `Base` subclass in this batch,
   never assumed.
3. **Pure mandatory arity, real raw-embeddable ivars, no unsafe attr
   collision** (`Game::Actor` -- 10 real fields; `Game::MessageConfig` -- 7;
   `RPG2k::Scene::DebugMenu`/`ItemMenu`/`Menu`/`Order`/`SaveLoad`/`Title` --
   1-4 each; `Game::NumberInput` -- 2; `Game::Shop` -- 1) -- every
   `attr_reader`/`attr_accessor` found on these classes is a plain,
   ivar-only exposure (`Game::Actor#transparent`, `Game::Shop#did_transaction`,
   `Game::NumberInput#digits`/`#cursor`, `Game::MessageConfig`'s whole
   `attr_accessor` list), exactly the `synthesizable_accessor_only?` safe
   exception this file's own `ATTR_STRUCT_DEVIRT` machinery exists for --
   confirmed in the regenerated code, not assumed: `Game::Actor#transparent`/
   `#transparent=` compile to real, synthesized struct-aware accessors
   (`Game__Actor_transparent`/`_transparent_eq`, overriding the plain native
   `attr_accessor` program-wide), and `Game__Actor_initialize_impl`'s own
   generated body allocates the `Game__Actor_ivars` struct via
   `mrb_data_init` as its very first statement, before any other write.

35 owners added to `BC2CPP_WIRED_EMBEDDINGS` in total (all `RPG2k::Scene::*`
menu/battle/map classes, `Game::Battle`/`Actor`/`Party`/`Shop`/`Enemy`/
`Troop`/`EnemyAi`/`TextReveal`/`MessageConfig`/`NumberInput`, and 7
`.singleton` pseudo-owners -- which never go through the instance-ivar
embedding path at all, per `drop_unsafe_embeddings`'s and the dispatch
logic's own explicit `owner.end_with?('.singleton')` special cases, so they
carry zero embedding risk by construction).

## What was verified

- `scripts/bc2cpp_wired_embedding_check.rb`: **PASS**, every one of the 35
  new owners at 100% (e.g. `RPG2k::Scene::Map: 408/408`, `Game::Battle:
  141/141`, `Game::Actor: 124/124`, `Game::Party: 128/128`) -- all 402
  previously-missing methods now installed.
- `scripts/bc2cpp_coverage_report.rb`: method-level coverage unchanged at
  100.0%, 0 `#error`. Compiled entry points 2320 -> 2343 (+23 synthesized
  `ATTR_STRUCT_DEVIRT` accessor overrides, 27 -> 50, exactly matching the
  attr-collision classes named above). Classes needing
  `MRB_SET_INSTANCE_TT` 14 -> 24 (the 10 real new embedding classes: Actor,
  MessageConfig, NumberInput, Shop, DebugMenu, ItemMenu, Menu, Order,
  SaveLoad, Title). `FIXNUM_RETURN_PROOF` 51 -> 58. Dynamic-dispatch `POLY`
  sites 3401 -> 3386 (-15, more devirtualization). `ivar embedding (EMBED)`
  stays 222 -- this count is `IvarLayout`'s own raw, wiring-independent
  result (see `docs/adr/0187`'s own correction of this exact
  misunderstanding), so it was never expected to move; the real ivar count
  is the `MRB_SET_INSTANCE_TT` list instead.
- All 22 `scripts/bc2cpp_*_check.rb` static checks pass.
- The regenerated real project `.cpp` inspected directly for the two
  highest-stakes classes: `Game__Actor_ivars` (10 fields: `id`,
  `face_index`, `transparent`, `battler_animation_override`,
  `class_changed`, `sprite_changed`, `row`, `level`, `faceset_index`,
  `class_id`), struct allocated first in `#initialize`'s own generated
  body, and the synthesized `transparent`/`transparent=` accessors
  correctly overriding the native `attr_accessor`.
- A full, from-scratch `RPGMAKER_BC2CPP=1` host build (all three
  `-compiled` gems, `libmruby.a`) rebuilt to completion with this change
  active.

## Consequences

Roughly 400 real methods across the game's own hottest, most
performance-relevant code -- the entire map scene update/render loop, the
full battle system, actor and party data access, seven menu scenes' own
`#initialize` and drawing methods -- now run as compiled C++ instead of
interpreted bytecode, and ten classes gain genuine primitive-field struct
embedding on top of that (removing `iv_bsearch_idx` dynamic ivar-table
lookups for those fields entirely). `Game::Actor` specifically closes the
exact gap `docs/adr/0186` flagged and declined to fix in scope -- it had
previously been embedded once already, hit the null-`DATA_PTR` class of bug
this whole registration-completeness mechanism exists to prevent by
construction, and was removed from `BC2CPP_WIRED_EMBEDDINGS` as a result;
this round re-adds it only after independently confirming the exact
registration gap that caused that removal is now closed for every one of
its 124 compiled entry points, not just `#initialize`.

Not measured in this round: actual wall-clock FPS impact (needs the real,
linked desktop game built and run, played through map/battle scenes, not
just the mruby static library this session could build) -- a real
follow-up, matching this ADR series' own repeated caveat that "compiles
clean and registers" is a prerequisite for a speed win, not proof of one on
its own (see `tools/optcarrot_probe/README.md`'s own extensive discussion
of registration completeness mattering independent of, and often more than,
ivar embedding for exactly this reason).
