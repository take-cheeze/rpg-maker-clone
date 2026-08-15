- An enemy's Autodestruct (self-destruct) attack no longer zeroes its own HP
  and grants full EXP / gold / item drops for a kill it never took. Verified
  against EasyRPG Player's actual C++ source
  (`Game_BattleAlgorithm::SelfDestruct`): the algorithm never writes the
  caster's own HP, only `SetHidden(true)`, so the caster is taken out of play
  the same way a fled monster is — not killed. `Game::Battle#enemy_autodestruct`
  now sets `hidden` instead of zeroing HP, and `Scene::Map#refresh_battle_sprites`
  mirrors that onto the troop member so `Troop#total_exp`/`#total_gold`/`#drops`
  correctly exclude it, matching the community デフォ戦bot trivia that a
  self-destructed enemy drops no reward, its HP reads unchanged if inspected,
  and "Enemy Appears" (Show Hidden Monster) brings it back exactly as before.
