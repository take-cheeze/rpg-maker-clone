- **RPG2000 EXP curve** (`Game::Actor#calc_exp`) runs its Float loop in C
  (`Game.exp_curve`), so computing a level's EXP no longer allocates a Float
  per step. Results are unchanged: `scripts/rpg2k/exp_curve_check.rb` compares
  it with the Ruby loop for every EXP-curve field in 0..100 and level 1..100.
