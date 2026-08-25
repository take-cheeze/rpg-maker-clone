- Message pacing control codes now act instead of being silently dropped:
  `\!` holds the typewriter until a button is pressed, `\.` and `\|` pause it for
  a quarter- and a full second, and `\^` closes the window once the text finishes
  without waiting for a keypress. `\_` inserts a space. `Game::Message.scan`
  surfaces these positions (counting the expanded length of `\v` / `\n`) and
  `Game::TextReveal` halts at each pause until it is released.
