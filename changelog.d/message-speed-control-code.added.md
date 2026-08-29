- **The `\s[n]` message control code (typewriter speed) is implemented**,
  previously dropped outright. `Game::Message.scan` records each `\s[n]` in
  revealed-character coordinates (`n` clamped to RPG_RT's real 1..20 range,
  confirmed against a reference implementation's message-window source
  rather than the editor's own documentation, though not independently
  confirmed against genuine RPG_RT under wine), and `Game::TextReveal` picks the speed in
  effect at the current reveal position, banking its per-frame character
  budget fractionally so a slower speed still reveals whole characters over
  several frames instead of stalling. `\s[]` produces no characters and
  burns no reveal tick, matching `\c[]`. As a consequence, the previously
  open "`\c[]`/`\s[]` bleed into an attached Show Choices list" finding is
  now fully resolved: a Show Choices list always reveals instantly, so the
  new speed state has nothing to bleed into.
