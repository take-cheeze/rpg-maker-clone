- Correct the RPG2003 front/back **row** mechanic to match the actual RPG_RT
  2003 behaviour, per a reference implementation's row-adjustment formulas
  — not independently confirmed against genuine RPG_RT under wine — instead
  of the earlier guess: a
  back-row defender is now a **flat 25 harder to hit** (was a 50% multiplier)
  and takes **-25% damage**, and a **front-row actor deals +25% damage** (the
  previously-deferred attacker-side adjustment; an enemy attacker is never
  row-adjusted). Physical skills are no longer row-adjusted at all — the
  reference gates skill rows behind a field of its own absent from real
  RPG Maker 2003 files. The attack hit/damage terms apply in the reference's
  own order (`Game::Battle#row_adjusted?`). RPG2000, which never sets a row,
  is untouched. Covered by reworked checks in
  `scripts/rpg2k3_battle_row_check.rb` (ADR 0053).
