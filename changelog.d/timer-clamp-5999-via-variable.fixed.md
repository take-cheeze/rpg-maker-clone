- **A Timer Operation "set" sourced from a Variable now clamps to 99:59
  (5999 s) instead of loading the raw value unbounded.** `Game::Timer#set`
  had no upper bound, and Control Variables can feed it an arbitrary
  player-reachable value through `Game::Interpreter#do_timer`. Real RPG_RT's
  timer display never grows past two minute digits, so it caps a set that
  high rather than wrapping. Added `Game::Timer::MAX_SECONDS = 5999` and a
  clamp in `#set`, with regression coverage in `scripts/rpg2k_logic_check.rb`.
