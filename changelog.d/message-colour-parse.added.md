- `Game::Message.parse` splits a message line into `\c[n]` **colour runs** —
  an array of `{text:, color:}` segments — expanding `\v`/`\n`/`\\` within each
  run and dropping the display-only codes, so the concatenated segment text
  still equals `Game::Message.expand`. This is the data layer for coloured
  message text; the window renderer will draw the runs in colour as a follow-up.
  `Message.expand` is now defined in terms of `parse`. Covered by new checks in
  `scripts/rpg2k_logic_check.rb`.
