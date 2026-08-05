- **An event that wipes the party now ends the game.** Game Over only ever
  followed a lost *battle*; the twelve commands that can knock the party out on
  the map — Change Party Member / EXP / Level / Parameters / Skills / Equipment
  / HP / MP / Condition, Full Heal, Simulated Attack and (RPG2003) Change Class
  — each re-check for it in RPG_RT and drop straight into Game Over, and none of
  them did here. A Simulated Attack damage floor strong enough to kill the party
  (Nepheshel has 850 Simulated Attacks) left the player walking around the map
  with a dead party. `Game::Interpreter#check_game_over` ports EasyRPG's
  `CheckGameOver`, including both of its guards: a battle-event page leaves
  defeat to the battle's own `[Defeat]` handler, and an **empty** party is not a
  wipe — a game that has taken every member away is between members, not over.
  It suspends on the same `:game_over` wait the Game Over command (12420)
  already raises, so the scene tears down exactly as before, and a Change EXP /
  Level / Class that kills the party goes to Game Over instead of announcing the
  level-up, matching RPG_RT's ordering.
