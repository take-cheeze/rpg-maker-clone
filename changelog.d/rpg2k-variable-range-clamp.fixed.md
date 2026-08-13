- RPG Maker 2000: a **Control Variables** write now clamps to RPG_RT's
  ±999999 range instead of overflowing. `Game::Variables#[]=` had no bound at
  all, so a Control Variables assign/add sourced from a large constant, an
  Input Number, or an expression like the standard `x1.5` = `x15/10`
  workaround (which can legitimately overshoot mid-computation) landed
  outside the range the real engine ever allows a variable to hold. Covered
  by a new `scripts/rpg2k_logic_check.rb` check (an over/under-range constant
  assign clamps at the boundary; an in-range add that would overflow clamps
  too), confirmed to fail against the pre-fix code.
