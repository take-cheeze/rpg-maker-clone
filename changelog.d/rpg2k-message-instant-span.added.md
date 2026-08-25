- Message text between `\>` and `\<` now reveals instantly instead of typing out
  character by character (RPG2000's instant-display span). `Game::Message.scan`
  records the spans and `Game::TextReveal` collapses each one in a single frame,
  while still stopping at any `\!` / `\.` / `\|` pause that falls inside the span.
  An unclosed `\>` runs to the end of the line.
