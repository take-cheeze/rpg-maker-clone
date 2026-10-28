- The closed build's class-body load folds computed constants to data at build time: `tools/bc2cpp/pure_eval.rb` runs a
  constant built by a block (`RGSS::Audio::EXT_SPELLINGS`, `Game::State::SYSTEM_SFX_SAVE_FIELD`) once under CRuby when it
  reads only literals, pure core methods and earlier frozen constants of its body, and the program spells the value
  (32-bit integers, float32-exact Floats, UTF-8 strings, Arrays/Hashes/Ranges, no shared unfrozen object). The fork's
  mruby computes the same statements in `class_body_check.rb` and the values are compared (class, frozen state, order,
  content). `EXTS` leaves the residual with them. A visibility send (`private :x`) whose every name is a def the build
  leaves out of its method tables is dropped too, and the defs it was keeping in the mrblib with it. The list of statements
  that stay bytecode is down to `DATABASE`, `MAP_UNIT`, `COMMON_EVENT` (lambdas), the three `LCF::INT32_*` (past 32 bits)
  and the two ordering aliases. `docs/bc2cpp-class-bodies.md`.
