- **Opening a battle now plays the database's Battle Start system SE**,
  matching real RPG_RT's `Scene_Battle` constructor (`src/scene_battle.cpp`),
  which plays `SFX_BeginBattle` as its very first act — before even swapping
  to the battle BGM. `Scene::Map#open_battle` already had every other
  system-SE slot wired up (cursor/decision/cancel/buzzer, Escape, the
  per-hit sounds) but never called `#play_system_se(SFX_BATTLE)`, so the
  database's own Battle Start sound (and any Change System SFX override for
  that slot) never played on any encounter — a foreground Enemy Encounter
  command, one issued from a Parallel Process, or a random/wandering-monster
  encounter alike, since they all share this one entry point. Covered by two
  new `scripts/rpg2k_scene_check.rb` checks (the database default plays the
  instant a fight opens; a Change System SFX override for the slot wins over
  it), both confirmed to fail against the pre-fix code before the fix.
