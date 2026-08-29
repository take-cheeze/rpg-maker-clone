- **Control Variables' Divide/Modulo now truncate toward zero like real
  RPG_RT's C++ math**, instead of mruby's native `/`/`%`, which floor toward
  negative infinity — the two only ever agreed when both operands shared a
  sign. `Game::Interpreter#apply` computed Divide/Modulo (op 4/5) as plain
  `cur / val` / `cur % val`; RPG_RT is itself a compiled C++ binary, so its
  own integer division and remainder follow C++'s truncate-toward-zero rule
  and dividend-signed remainder directly, the same C++-vs-mruby gap this
  codebase already ported for a different division
  (`Scene::Map.tone_channel`'s own tone-conversion truncation, "the
  reference does this in C++ integer arithmetic") — e.g. `-7 / 2` is −3 in
  C++ but mruby's floored `/` gives −4, and `-7 % 2` is −1 in C++ (the
  remainder takes the dividend's sign) but mruby's `%` gives 1 (the divisor's
  sign) — a real divergence for any game whose Control Variables math ever
  goes negative. Fixed with two new helpers, `#trunc_div`/`#trunc_mod`, the
  same truncating idiom. Divide-by-zero was already correct (`cur`
  unchanged, matching a reference implementation's own variable-divide
  behaviour, ported from that source and not independently confirmed against
  genuine RPG_RT under wine) and is untouched; **modulo by zero now zeroes
  the variable instead of leaving it unchanged**, matching that same
  reference's own variable-modulo behaviour (same unconfirmed basis), which
  disagrees with the divide case's behaviour on this exact point.
