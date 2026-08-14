- **Control Variables' Divide/Modulo now truncate toward zero like real
  RPG_RT's C++ math**, instead of mruby's native `/`/`%`, which floor toward
  negative infinity — the two only ever agreed when both operands shared a
  sign. `Game::Interpreter#apply` computed Divide/Modulo (op 4/5) as plain
  `cur / val` / `cur % val`; EasyRPG's `Game_Variables::VarDiv`/`VarMod`
  (`src/game_variables.cpp`) are bare C++ `n / d` / `n % d`, so e.g. `-7 / 2`
  is −3 there but mruby's floored `/` gives −4, and `-7 % 2` is −1 there (the
  remainder takes the dividend's sign) but mruby's `%` gives 1 (the divisor's
  sign) — a real divergence for any game whose Control Variables math ever
  goes negative. Fixed with two new helpers, `#trunc_div`/`#trunc_mod`, the
  same truncating idiom this codebase already uses elsewhere for a different
  C++-vs-mruby division gap (`Scene::Map.tone_channel`). Divide-by-zero was
  already correct (`cur` unchanged, matching `VarDiv`'s `d != 0 ? n / d : n`)
  and is untouched; **modulo by zero now zeroes the variable instead of
  leaving it unchanged**, matching `VarMod`'s own `d != 0 ? n % d : 0`, which
  disagrees with `VarDiv`'s behaviour on this exact point.
