- **RPG2000's Test Play debug keys are implemented.** Holding **Ctrl** ignores
  collision the same way Through Mode does and suppresses the random-encounter
  roll; holding **Shift** fast-forwards the current message the same way a
  C/B press does (complete the reveal, then advance/close once it is fully
  shown); and **F9** opens a debug menu that lists every switch and variable
  ten at a time (Left/Right flips between the two, Up/Down moves the cursor,
  L/R jumps a page, C toggles a switch or opens a signed number editor for a
  variable). All three are gated on Test Play (`RPG2k#test_play`, see the
  `--test_play` flag) exactly like the rest of the debug tooling — a released
  game never sees any of them do anything.
