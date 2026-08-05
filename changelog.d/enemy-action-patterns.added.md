- RPG2000 enemies now run their **行動パターン** (action pattern, enemy chunk 42)
  instead of only ever swinging their fists. `Game::EnemyAction` decodes the
  table, and each turn `Game::Battle` keeps the entries whose condition holds and
  picks one weighted by `rating` — EasyRPG's rating-based algorithm, including
  the rule that drops anything more than 10 below the best rating, so a monster's
  behaviour shifts as its better moves stop being valid. All eight condition
  types are modelled (always / switch / turn / party size / HP% / SP% / party
  level / fatigue), the turn condition reusing `Game::BattlePage.check_turns`.
  Every action kind runs: **skills** (cast through the same pipeline the party
  uses, so an enemy's spell is costed, elementally scaled, accuracy-rolled and —
  finally — **inflicts its states on the party**, closing the last enemy-cast
  gap), **transformations** into another database enemy, and the basic actions
  (attack, dual attack, defend, observe, charge for a double-damage next blow,
  self-destruction for `atk - def/2` across the party, escape, do nothing). An
  action's post-run switch on/off is applied, so a monster's move can drive the
  troop's battle-event pages. Enemies are fed the database and game state through
  a new `Game::EnemyAi` collaborator, keeping `Game::Battle` itself database-free;
  without one an enemy falls back to plain attacking exactly as before. This was
  a large silent gap: 510 of the 959 enemy actions across the two test beds are
  skills that never fired. Verified by running every troop in both test beds
  (157 and 88 fights, no errors), where 1980 and 1193 skill casts now land.
