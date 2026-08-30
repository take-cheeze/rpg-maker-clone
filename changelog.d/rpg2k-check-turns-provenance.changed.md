- RPG Maker 2000: recorded where `Game::BattlePage.check_turns` comes from and
  pinned it to that source. Both the body and the argument order are ported
  from a reference implementation's own turn-check function — taking
  `(turns, base, multiple)` and called as `(GetTurn(), condition.turn_b,
  condition.turn_a)` — so `base` is the page's `turn_b` and `multiple` its
  `turn_a`, which reads backwards from the field names and is worth writing
  down; this ordering is not independently confirmed against genuine RPG_RT
  under wine. A new check cross-checks the Ruby against that C expression over
  a grid of turn / base / multiple values, so the simplification of the
  `multiple == 0` branch to `turn == base` stays honest. The comment also now
  states what the real-game data can and cannot show: every turn-gated page in
  the games checked so far has `turn_b == 0`, so a swapped argument order
  would produce the same observed behaviour — the ordering rests on the
  reference source, not on the data.
