- Enemy Encounters now open a **battle screen** on the map (the skeleton of the
  turn-based battle). It shows a status panel — the enemy troop and each party
  member's HP — over a **Fight / Flee** command menu. Choosing *Fight* resolves
  the battle (via `Game::Battle`) and shows the result (Victory with EXP / gold,
  or defeat); *Flee* escapes when the encounter allows it. Dismissing the result
  resumes the event with the outcome, routing the `[Victory]` / `[Escape]` /
  `[Defeat]` handler branch as before. `Scene::Map` drives it during the
  `:battle` wait, the same way it drives the shop and inn. Still to come: the
  per-actor command menu (Attack / Skill / Item / Defend + targeting), per-turn
  animation from the combat log, enemy / battler sprites, and game over on
  defeat. Covered by updated / new checks in `scripts/rpg2k_scene_check.rb`
  (Fight → win / lose, and Flee → escape).
