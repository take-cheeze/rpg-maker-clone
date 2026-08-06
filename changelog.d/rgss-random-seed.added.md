- **`--rgss_random_seed` makes a headless RGSS run reproducible.** mruby seeds
  its generator from the clock, and a game's own engine rolls constantly — the
  encounter count as the party is placed, damage variance, the order the battlers
  act in — so two runs of the same check drive two different games. Fine for a
  player, useless for a check: the boot check's battle pass passed twice and then
  failed inside the game's own `make_action_orders`, with no way to ask for that
  run back. The seed is applied at the last moment before the game's own scripts
  run, so nothing of ours can consume a value first and shift every roll the game
  makes, and the host logs it. `0` (the default) leaves the clock seed alone.
  `scripts/rpgxp_boot_check.bash` pins one and prints it, and
  `RPGXP_RANDOM_SEED` overrides it for hunting a failure only some seeds reach.
