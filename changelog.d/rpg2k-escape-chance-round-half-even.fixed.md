- **The battle escape-chance formula now rounds an exact tie to the nearest
  even whole percent**, instead of always rounding up — the same
  rounding-mode gap the `fatigue` condition had. Ported from a reference
  implementation, not independently confirmed against genuine RPG_RT under
  wine: its rounding helper uses the default IEEE 754 rounding mode, which
  rounds an exact `.5` to the nearest even integer, not up. A party at
  average agility 200 against an enemy average of 101 computes the ratio
  50.5 exactly before rounding — the reference implementation lands on 50
  (escape chance 100), this engine previously landed on 51 (escape chance
  99).
