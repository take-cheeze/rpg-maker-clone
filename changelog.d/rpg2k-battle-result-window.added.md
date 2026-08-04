- Winning or losing an Enemy Encounter now shows an on-map **battle result
  window** before returning to the event. `Scene::Map` runs the battle, then
  displays the outcome — `Victory!` with the EXP and gold gained, or `The party
  was defeated...` — and waits for a confirm before resuming the interpreter (and
  routing the `[Victory]` / `[Defeat]` handler branch). Rewards are still granted
  only on a win. This is the first visible piece of the battle screen; the full
  turn-based battle (party / enemy display, HP, the command menu and per-turn
  animation from the combat log) is still to come. Covered by new checks in
  `scripts/rpg2k_scene_check.rb` (a win shows the result then runs Victory; a
  loss shows the defeat text, grants nothing and runs Defeat).
