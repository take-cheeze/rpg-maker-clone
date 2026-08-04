- Six more RPG2000 event commands are now handled. **Input Number** (10150)
  suspends the interpreter on a `:number` request the map scene answers with a
  digit-entry widget (backed by a testable `Game::NumberInput` model), storing
  the entered value into the target variable. **Change Actor Name** (10610),
  **Change Actor Title** (10620) and **Change Sprite Association** (10630) mutate
  a party actor's name, status-screen title, and CharSet graphic / transparency
  — `Game::Actor` gains the writable `name` / `title` / `transparent` fields and
  a `set_charset`, seeded from the database row (`title`, `semi_transparent`),
  and the scene reloads the leader's on-screen sprite when it changes. **Halt All
  Movement** (11350) cancels every forced move route in progress (the player's
  and each event's). These edits also survive a Save / Continue: `Game::Party`
  now round-trips each actor's name / title / sprite overrides. Covered by new
  checks in `scripts/rpg2k_logic_check.rb` and `scripts/rpg2k_scene_check.rb`.
