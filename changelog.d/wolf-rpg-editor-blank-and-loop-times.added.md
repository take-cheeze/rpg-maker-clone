- **WOLF RPG Editor (ウディタ/Woditor)** `Blank`(0) — the single most common
  command code in the bundled sample game (3468 real occurrences, always
  empty) — is now a deliberate no-op instead of logging as unimplemented.
  `LoopTimes`(179) ("回数付きループ", 438 real occurrences) now repeats its
  body a real, possibly variable-held number of times, sharing
  `StartLoop`(170)'s own `LoopEnd`(498) terminator; `BreakLoop`/
  `GotoLoopStart` both work inside it, and two manual-documented edge cases
  — 0-or-fewer configured iterations never running the body, and a label
  jump landing inside the loop from outside it running exactly once
  regardless of the configured count — are handled exactly, not
  approximated. See
  `docs/adr/0076-wolf-rpg-editor-blank-and-loop-times.md`.
