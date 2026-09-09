# 124. Split mruby-rpg2k's remaining battle-only helpers out of game.rb/interpreter.rb/scene/base.rb; fix a live `Battle::` constant reachable on wio

Date: 2026-09-09

## Status

Accepted

## Context

ADR 0107 already excludes `mruby-rpg2k/mrblib/game/battle.rb`, `scene/
battle.rb` and `scene/battle_rpg2k3.rb` from the wio build (`mrbgem.rake`,
`build.name == 'wio'`); ADR 0097 excludes the three F9-debug-tool files
(`scene/debug_menu.rb`, `scene/chipset_editor.rb`, `scene/map_viewer.rb`) for
`psp`/`wio` both. Neither ADR went looking for *further* code left dead by
those exclusions inside the files that stay -- `game.rb`, `interpreter.rb`
and `scene/base.rb` are the shared field-engine files every target keeps, so
nobody had a reason to re-audit them once the obviously battle-only files
were already gone.

Grepping every real (non-comment, non-CRuby-`scripts/*_check.rb`) call site
of the methods/classes those three files define turns up a second, larger
layer of dead code inside the files wio *does* keep, in three shapes:

- **Whole classes only ever instantiated from an excluded file.** `Game::
  Troop` is built only by `scene/battle.rb:150`; `Game::Enemy` only by
  `Troop#member`, `Game::EnemyAi#enemy` and `scene/battle.rb:1266` -- all
  three already dead or excluded; `Game::EnemyAction` only by `Enemy#
  initialize`. `Game::EnemyAi` is built only by `scene/battle.rb:184`. Four
  classes, one dependency chain, all unreachable once `scene/battle.rb` is
  gone.
- **Whole modules with no caller outside the excluded files.** `Game::
  BattlePage` (troop battle-event-page condition evaluation) is called only
  from `game/battle.rb`/`scene/battle.rb`. `Game::States::BattleText` (every
  battle-log sentence builder -- `damage`, `critical`, `dodge`, `skill_start`,
  `item_start`, ...) and its neighbours `inflict_message`/`recovery_message`/
  `affected_message`/`already_message`/`field`/`message`/`animation_pose`
  read the same way.
- **A labelled, self-contained section and individual methods.** `Game::
  Party`'s own `# -- Battle-context skill / item use --` header (game.rb)
  marks a 500-line run (`battle_skills` through `item_all_allies?`) that
  turns out to be the *entire remainder of the class* -- plus
  `#skill_helps_troop?`, sitting just above the header, called only by the
  now-dead `EnemyAi`. Scattered singles: `Game::Actor#alive?`/`#atb_gauge=`/
  `#attack_animation_id`/`#weapon_sp_cost`/... (13 methods), `Game::Party#
  gauge_battle_layout?`/`#automatic_battle_placement?`, `Game::Map#
  sync_layers_to_unit` (dead via the debug-tools exclusion, not battle --
  `map_viewer.rb`'s own chipset editor was its only caller), `Game::
  Interpreter#take_revealed_monsters`/`#take_fled_monsters`/
  `#take_monster_kills`/`#take_battle_background` (battle-event-page drain
  accessors; their sibling `#take_battle_animation_request` stays -- `scene/
  map.rb:4344` reads it for the map's own Show Battle Animation command,
  which does not need a running fight) and `Scene::Base#
  advance_list_arrow_anim`/`#list_arrow_blink_on?`/`#sticky_list_top`/
  `#wrap_text_to_width`/`#draw_wrapped_hint`/`#screen_width`/`#screen_height`
  (the last five map-viewer/chipset-editor-only, not battle).

Every removal candidate was checked the same way, not assumed: grep its name
across every `mruby-rpg2k`/`mruby-rgss`/`mruby-lcf` `.rb` file plus
`scripts/*.rb`, read each surviving hit in context, and confirm it is either
the definition line itself, a prose comment, an unrelated same-named method
on a different class (`alive?` also exists on mruby's own `Fiber`; `screen_
width`/`height` also exist on `mruby-wolf/mrblib/data.rb`'s own `Data` class),
or a `scripts/*_check.rb` call (a CRuby-only test harness, never compiled
into any real target). A few near-misses stayed: `Game::Party#
use_skill_item_usable?` takes an `in_battle` flag and is genuinely called by
both `#field_usable?` and the (now-moved) `#battle_usable?`, so it stayed in
`game.rb` untouched; `Game::Party#cast_skill` sits inside the labelled
section's own line range by chance but is the general field-and-battle skill
-casting routine `scene/skill_menu.rb` calls, so it was excluded from the
moved span by hand.

**A real bug, found the same way ADR 0123 found `LCF::Database`'s gap:**
`Game::Actor#state_persists_type?` (called by `#remove_state`, whenever
`always_remove_battle_states:` is true -- which `interpreter.rb`'s Change
Condition handler passes as `@battle.nil?`, i.e. on *every* ordinary
non-battle state cure) and `Game::Party#field_skill?` (the field Skill
menu's own grey-out check, `scene/skill_menu.rb`) both read `Battle::
STATE_PERSISTS_ON_MAP` -- a constant that lives on `Game::Battle`, one of
the classes wio already excludes. Neither call site is inside anything this
ADR moves; both are ordinary, frequently-reached field/map code. A wio build
curing a status condition outside a fight (an antidote from the Item menu,
a "Remove Poison" Change Condition event, opening the field Skill menu on
any state-only skill) hits a live `NameError: uninitialized constant
Game::Battle` today, unrelated to anything this ADR trims.

## Decision

**Fix the bug first.** `Game::States` (game.rb, compiled on every target)
gains `PERSISTS_ON_MAP = 1`, the real definition; `Game::Battle::
STATE_PERSISTS_ON_MAP` becomes `States::PERSISTS_ON_MAP` (an alias, so
`game/battle.rb`'s own many internal bare references keep resolving
unchanged), and the two live call sites read `States::PERSISTS_ON_MAP`
instead of `Battle::STATE_PERSISTS_ON_MAP`. Verified by loading `game.rb`+
`interpreter.rb` alone under CRuby with `Game::Battle`/`Troop`/`EnemyAi` all
left undefined (the real wio shape) and calling both fixed methods directly:
no `NameError`, same as calling them with `battle.rb` loaded.

**Move the dead code, don't delete it.** Two new files, loaded after the
files they reopen (`Dir.glob(...).sort`: `game.rb` < `game/battle_support.rb`,
`scene/base.rb` < `scene/battle_support.rb`, so the classes already exist):

- `mruby-rpg2k/mrblib/game/battle_support.rb` reopens `Game::Actor`/`Party`/
  `Map`/`Interpreter`/`States` for the scattered methods, plus `Game::
  BattlePage`, `Game::EnemyAction`/`Enemy`/`Troop`/`EnemyAi` and `Game::
  States::BattleText` verbatim (their own class/module keywords moved with
  them).
- `mruby-rpg2k/mrblib/scene/battle_support.rb` reopens `RPG2k::Scene::Base`
  for its seven methods.

`mrbgem.rake` excludes both new files under the same `build.name == 'wio'`
condition as the existing battle-file exclusion (a second `if`, not folded
into the first, since it is conceptually the same "battle is gone" trim
landing as a follow-up, not a rename of the original). `psp` is untouched --
it keeps every battle file, so it keeps both support files too.

**Every `scripts/*_check.rb` that `load`s `game/battle.rb` individually
(rather than through a glob) gets one more `load` line for `battle_support.
rb` right after it** -- the same fix ADR 0123 applied for `lcf_file.rb`, and
for the identical reason: these CRuby harnesses `load` exact files, not a
directory glob, so a file split invisible to `spec.rbfiles`' own default glob
is not invisible to them. Ten call sites: `analyze_game.rb` was *not* one of
them (it loads `interpreter.rb` alone, never `game.rb`, and exercises none of
the moved interpreter methods). `scripts/rpg2k_scene_check.rb`'s own `scene/
*.rb` files already load through `Dir[...].sort.each { load }`, so `scene/
battle_support.rb` needed no extra line there -- only its `game/battle_
support.rb` counterpart did (that gem still loads individually).

### What was verified

- `ruby scripts/rpg2k_logic_check.rb`: **1201 checks passed** (unchanged).
- `ruby scripts/rpg2k_scene_check.rb`: **1062 checks passed** (unchanged).
- `ruby scripts/rpg2k3_battle_gauge_check.rb` / `rpg2k3_battle_row_check.rb`:
  **15 / 19 checks, 0 failures** (unchanged).
- `ruby scripts/rpg2k_render_check.rb`: **41 checks passed** (unchanged).
- `ruby scripts/rpg2k_save_load_check.rb`, `export_nano7_map_check.rb`,
  `rpg2k_command_soak.rb`, `rpg2k_testbed_logic_check.rb`: load and run
  cleanly (the latter two skip their own real-game-data checks in this
  sandbox, same as before this change -- no test-bed downloaded).
- A standalone CRuby smoke script loaded `game.rb`+`interpreter.rb` alone
  (no `battle.rb`, no `battle_support.rb` -- the real wio shape) and called
  `Actor#state_persists_type?`, `Actor#remove_state(always_remove_battle_
  states: true)` and `Party#field_skill?` directly: all three ran and
  returned, where every one previously would have raised `NameError:
  uninitialized constant Game::Battle`.
- `mrbc` (built from this checkout's own vendored `3rd/mruby`, no `-g`) on
  the full 22-file mrblib (every gem file, host/desktop shape): compiles
  clean, exit 0 -- no duplicate-definition or load-order errors from the
  split.
- `mrbc --remove-lv` (matching wio's real `conf.mrbc.compile_options`, ADR
  0115) on the wio-shaped 14-file set (debug tools, battle, and the two new
  support files all excluded): **524,979 -> 501,438 bytes**, a real
  **23,541-byte (4.5%)** cut to `mruby-rpg2k`'s own wio bytecode, on top of
  everything ADR 0097/0107/0121 already took.
- No real ARM `wio_rgss_boot` relink was run in this sandbox (no `arm-none-
  eabi-g++`/PlatformIO/Arduino-SAMD-framework toolchain here) -- the `mrbc`
  byte count is the same proxy ADR 0097/0098 used before a real link was
  available to them, and ADR 0115's own two-stage measurement (a host `mrbc`
  estimate, later confirmed by a real relink that landed close to it) is the
  closest precedent for how well that proxy tracks the real number here.

## Consequences

- **A real, if modest, flash cut** (23,541 bytes / 4.5% of `mruby-rpg2k`'s
  own wio bytecode) plus **a real crash fixed** on every wio build that ever
  reaches a state cure outside battle or opens the field Skill menu on a
  state-only skill -- previously true of *any* wio build with `game/battle.
  rb` excluded, i.e. every wio build since ADR 0107 landed, not something
  this ADR's own trim introduces.
- **`psp` is unaffected**: it keeps `game/battle.rb`/`scene/battle.rb`/
  `scene/battle_rpg2k3.rb` and now also keeps the two new support files,
  so its own compiled bytecode is unchanged (the constant fix applies to it
  too, harmlessly -- `Battle::STATE_PERSISTS_ON_MAP` still resolves the same
  value, just via the alias).
- **`RGSS_WIO_EXTERNAL_RPG2K` (ADR 0108) still works unchanged**: it sets
  `spec.rbfiles = []` before either wio-only `if` runs, so it drops the two
  new files exactly as it already dropped everything else.
- **This is very likely the last easy win of this specific shape.** The
  dependency chain this ADR walked (`Troop` -> `Enemy` -> `EnemyAction`,
  `EnemyAi`, `BattlePage`, `BattleText`, the labelled Party section) is now
  fully pruned; what remains in `game.rb`/`scene/map.rb`/`interpreter.rb` is,
  per ADR 0097's own framing, "the field engine itself" -- reachable from an
  ordinary play session, not optional. ADR 0108's own conclusion (once
  `mruby-rpg2k`'s Ruby is zero, the ~1 MB interpreter+RGSS+LVGL+uni-algo+
  Arduino skeleton is still ~2x the board's budget by itself) is not
  contradicted by this smaller, safer trim; it is not revisited here either
  -- this ADR only re-confirms that trimming *this* gem's own dead weight,
  the lever ADR 0097/0107/0121 already used, still had a little left in it
  after ADR 0107's split, not that it is now enough on its own.
