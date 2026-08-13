- **The `\<` (instant-span close), `\$` (show gold) and `\^` (auto-close)
  message control codes now burn one tick of display time**, matching
  yado.tk: they render no character but RPG_RT still advances the
  typewriter counter for them, unlike `\c[]`/`\s[]` or `\>` (span open),
  which stay free. `Game::Message.scan` advances its reveal-coordinate
  `count` by one for those three codes; an instant span's own two
  characters are unaffected (the tick lands right after the span closes,
  not inside it), so text right after one of these codes now reveals one
  frame later than before.
