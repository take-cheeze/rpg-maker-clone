- **MZ's battles were frozen, and the smoke test was green over it.** The battle
  check asserted `Scene_Battle` was reached — which is true the instant the scene
  is pushed, before its first update. Writing a probe that *plays* the fight
  (`--mz_battle_play`, `MZ_MODE=battle_play`: tap confirm through the party,
  actor and target windows and watch the enemy's HP) showed combat had never
  worked: `BattleManager._phase` stayed at `"start"` forever and no window ever
  opened. `Sprite_Enemy` only loads a bitmap when the battler name it reads
  differs from the one it holds, and both were `""` in the test bed, so
  `this.bitmap` stayed undefined and the next line of `updateFrame` read
  `.width` off it — throwing on every frame, inside `Scene_Battle.update`, which
  skipped everything after it: no window layer update, so the battle-start
  message never cleared, so `BattleManager.isBusy()` never went false. The bed
  now ships a battler image, plus the `xparam` HIT traits without which every
  physical attack misses (hit rate is `successRate * 0.01 * subject.hit`, and
  `hit` defaults to 0). The fight now runs 100 HP to 0, wins, and returns to the
  map. The frame check's exemption for the "legitimately near-black" battle
  frame is gone with it — that frame was dark because the scene was broken, and
  the exemption was what let it stay that way.
