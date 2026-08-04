- `Game::Battle` is now **turn-stepped and logged**, the substrate the on-screen
  battle will animate. `#step` performs one battler's action at a time — living
  battlers act in agility order, a new round refills the queue — and appends a
  `#log` entry (`attacker`, `target`, `damage`, `target_hp`, `defeated`); `#run`
  steps to completion for the headless resolution as before, and `#finished?`
  reports when a side is wiped. Until the battle screen exists, `Scene::Map`
  traces a resolved encounter blow-by-blow to the console from the log. Covered
  by new checks in `scripts/rpg2k_logic_check.rb` (step-by-step advance + log
  entries, `run` records every hit).
