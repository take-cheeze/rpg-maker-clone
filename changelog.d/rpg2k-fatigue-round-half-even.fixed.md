- **The RPG2003 party `fatigue` condition now rounds an exact tie to the
  nearest even whole percent**, instead of always rounding up. Ported from a
  reference implementation, not independently confirmed against genuine
  RPG_RT under wine: its rounding helper uses the default IEEE 754 rounding
  mode, which rounds an exact `.5` to the nearest even integer (banker's
  rounding), not up. A single ally at max HP 16 / current HP 3 with no SP
  computes exactly 12.5 before rounding — the reference implementation lands
  on 12, this engine's round-half-up previously landed on 13, one point
  apart on the `fatigue` page condition / RPG2003 enemy-AI threshold at that
  exact boundary.
