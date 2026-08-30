- **A skill's percent-based SP cost is now RPG2003-only, and half-SP-cost
  gear now rounds a percent-based cost down instead of up.** Ported
  from a reference implementation, not independently confirmed against
  genuine RPG_RT under wine: RPG2000's editor has no percent-cost UI at
  all, so a stray `sp_type` byte on an RPG2000 database should read as an
  ordinary fixed cost instead. Separately, half-cost gear rounds a fixed cost
  up but a percent cost down — applying the fixed-cost rounding to both
  previously overcharged a percent-cost skill by up to 1 SP whenever its own
  intermediate cost came out odd, up to a full 100% overcharge for some
  gear/skill combinations.
