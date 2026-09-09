- **`Game::Battle` moved into its own file** (`mruby-rpg2k/mrblib/game/battle.rb`,
  split out of `game.rb`, where it was the single largest class in the
  file), so it can be named in a build's file list the same way
  `scene/battle.rb` already could. Found and fixed a real, pre-existing
  layering issue along the way: the field-menu Row command
  (`Game::Party#toggle_actor_row`) and the status panel's row indicator
  both read `Battle::ROW_FRONT`/`ROW_BACK` even though neither requires a
  fight to have ever started — both constants now live on `Game::Actor`
  (which already needed them), with `Game::Battle` keeping its own copy as
  an alias for its ~15 existing internal call sites. Verified
  behavior-neutral: the full test suite plus every real RPG2003
  battle-mechanic check script (row, gauge, command data model, a real
  fight in `rpg2k_scene_check.rb`) all pass unchanged.
- **The Wio Terminal build now excludes `Game::Battle`/`scene/battle.rb`/
  `scene/battle_rpg2k3.rb`'s compiled bytecode** (180,368 bytes measured
  standalone) — real, measured savings: flash overflow drops by 137,632
  bytes, and RAM now fits its 192 KB budget entirely (previously 17,576
  bytes over). This is *wio-only*, not PSP, and — unlike this project's
  existing debug-tools trim — comes with no way to load battle back in yet:
  no runtime SD-bytecode loader exists for wio, so this proves the split
  and measures its cost rather than shipping a complete feature. See
  ADR 107.
