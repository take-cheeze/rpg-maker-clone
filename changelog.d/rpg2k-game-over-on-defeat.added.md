- RPG Maker 2000: **losing a battle can now end the game**. When an Enemy
  Encounter set to the default *game over* defeat mode (no custom `[Defeat]`
  handler) wipes the whole party, `Scene::Map#finish_battle` returns to the title
  screen instead of resuming the event. It is gated on the party actually being
  wiped: `Game::Party#all_dead?` / `#any_alive?` report the game-over condition
  (every member 戦闘不能), evaluated after the battle's HP write-back so a downed
  party is seen as downed. A defeat routed to a custom `[Defeat]` handler still
  runs that branch as before — only the game-over defeat mode returns to the
  title. Covered by a new `scripts/rpg2k_scene_check.rb` check (a frail party is
  overwhelmed and the scene hands back to the title) and
  `scripts/rpg2k_logic_check.rb` checks for the party predicates. A dedicated
  Game Over graphic before the title remains a follow-up.
