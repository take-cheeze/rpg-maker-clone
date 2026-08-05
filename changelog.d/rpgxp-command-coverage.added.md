- `scripts/rpgxp_command_coverage.rb` reports what share of a real RPG Maker XP
  game's event commands the interpreter actually handles — the counterpart of
  `scripts/analyze_game.rb` for XP, and the answer to the same blind spot:
  `scripts/rpgxp_testbed_check.rb` deliberately treats an unsupported command as
  "skipped, not fatal", so a game could run end to end through it while a
  meaningful share of its commands did nothing. It classifies each code as
  implemented (the interpreter names it), no-op (the list terminator, and the
  Move Route continuation 509 — verified against the data, where all 2487 of Pray
  for You's follow a 209 or another 509) or a gap, and reports a gap by number
  rather than inventing a name for a command that is not implemented.
