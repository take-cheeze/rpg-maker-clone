- **Wio Terminal: dropped ~23.5 KB more of `mruby-rpg2k`'s own dead bytecode.**
  ADR 0107's battle exclusion left a second layer of now-unreachable code
  behind in the files wio keeps -- `Game::Troop`/`Enemy`/`EnemyAction`/
  `EnemyAi`, `Game::BattlePage`, `Game::States::BattleText` and a handful of
  scattered `Actor`/`Party`/`Map`/`Interpreter`/`Scene::Base` methods, all
  reachable only from the already-excluded battle/debug-tool files. Moved
  into two new files (`mruby-rpg2k/mrblib/game/battle_support.rb`,
  `scene/battle_support.rb`) and excluded on wio the same way; `psp` keeps
  everything unchanged. See ADR 124.
