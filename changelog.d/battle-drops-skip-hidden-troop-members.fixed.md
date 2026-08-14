- **A troop member still `hidden` at the moment of victory — never revealed
  by its own Show Hidden Monster page, or sent running by that page's Force
  Flee — no longer hands over EXP, gold or a treasure drop it never actually
  fought or fell for.** `Game::Battle#incapacitated?` (`mruby-rpg2k/mrblib/
  game.rb`) already treats a hidden member the same as a dead one for
  win/loss purposes, so victory can fire the instant every *visible* member
  is down, with no requirement that a still-hidden one ever engaged.
  `Game::Troop#total_exp`/`#total_gold`/`#drops` summed/rolled every member
  unconditionally, with no such check — verified against EasyRPG Player's
  actual C++ source: `Game_EnemyParty::GetExp`/`GetMoney`/`GenerateDrops`
  (`src/game_enemyparty.cpp`) each gate on `enemy.IsDead()`, a bare
  `GetHp() == 0` check that a hidden or fled member (never damaged, only ever
  `SetHidden`) always fails. Fixed with a new private `Troop#live_members`
  (`@members.reject(&:hidden)`) that all three methods now route through.
  Covered by a new `scripts/rpg2k_logic_check.rb` check, confirmed to fail
  against the pre-fix code before the fix.
