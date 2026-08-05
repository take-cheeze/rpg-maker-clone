- `scripts/analyze_game.rb` now refuses to run when its move-name table has
  drifted from the runtime. `MOVE_NAMES` has silently disagreed with the ids it
  describes before, and a drifted label table is worse than none: the report
  keeps working and quietly attributes a game's commands to the wrong ones.
  Names cannot be machine-checked in general — nothing in the runtime spells out
  the string `MoveTowardHero` — but `Game::Interpreter::MoveCmd` pins four ids by
  name (32..35, because those carry extra parameters the interpreter decodes),
  and they sit exactly in the span where the last drift landed. A mismatch now
  aborts with which side moved and what to check, instead of printing a
  plausible-looking histogram.
