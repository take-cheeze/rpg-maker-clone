- RPG Maker 2000: a batch (range) **Control Variables** random-assign now
  rolls independently for each variable in the range, matching RPG_RT —
  `Var[1..5] = random 1~6` is five separate dice, not one roll broadcast to
  all five. `Game::Interpreter#do_control_vars` used to evaluate its operand
  once before the range loop and reuse that single value for every id;
  harmless for a constant or a variable/item/actor read, but wrong for the
  random operand. Every other operand type keeps its existing once-up-front
  evaluation. Covered by a new `scripts/rpg2k_logic_check.rb` check.
