- **A batch (range) Control Variables write whose own operand reads a
  variable inside the destination range it writes now splits at the source
  instead of broadcasting one value to the whole range.** Verified against
  EasyRPG Player's actual C++ source: `Game_Variables::WriteRangeVariable`
  (`src/game_variables.cpp`), reached whenever
  `Game_Interpreter::CommandControlVariables` (`src/game_interpreter.cpp`)
  sees a direct-variable operand (type 1, "Var A ops B") applied to a genuine
  multi-id range, writes ids at or before the source from its value *before*
  the command touched anything, then writes ids after the source from its
  value *after* that first pass already updated it — so `Var[1..5] += Var[3]`
  leaves ids 4-5 combining with a different number than ids 1-3 whenever the
  operation is anything but a plain Set. `Game::Interpreter#do_control_vars`
  (`mruby-rpg2k/mrblib/interpreter.rb`) always read its operand once up front
  and broadcast that single value across the whole range, which happened to
  match RPG_RT except in this one self-referential case. Fixed with a new
  `#do_control_vars_range_variable`, ported from `WriteRangeVariable`'s
  two-pass split; a source outside the destination range still degenerates
  to the original single-read behaviour, and every other operand type
  (constant, indirect, random, item, actor, ...) is untouched. Covered by a
  new `scripts/rpg2k_logic_check.rb` check, confirmed to fail against the
  pre-fix code before the fix.
