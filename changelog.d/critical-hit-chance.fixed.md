- **A weapon's critical-hit bonus counts now.** RPG2000 stores a critical chance
  in two shapes — the actor row's 1-in-N denominator plus a flat percentage from
  the equipped weapon — and this build modelled only the denominator, which has
  nowhere to put "+10%". So all **75** of Nepheshel's `critical_hit` bonuses did
  nothing. The chance is carried in basis points now and the two sources sum on
  that scale (ADR 0034): with リト's 1/20 row, a +2% dagger gives 700 bp, a +10%
  falchion 1500, and 滅びの剣's +60% 6500. Across every troop in the game the
  party goes from **29 criticals to 141**, ending fights 240 swings sooner and
  winning five more of its 157 fights.
- **The bonus is read from weapons only**, which the data makes worth saying: of
  the 75 items Nepheshel sets the field on, the six carrying **+100%** are all
  armour or accessories (龍の鱗, 光の衣, 翼 …). Reading those would hand out gear
  that criticals on every blow. RPG_RT iterates weapons and skips every armour
  slot, so the field is inert outside the weapon slot — as its sibling `hit`
  already was.
- **New `Game::Rng#scaled`**, used by the crit roll. The generator's period is
  prime, so `next_int % n` leaves the low `period % n` values over-represented.
  At the small `n` every existing caller uses that is invisible; at the scale a
  basis-point chance needs it is not — `random(10000) < 333` fires 3.562% of the
  time where 1/30 is 3.333%, which would have quietly added a ~7% relative crit
  boost on top of the feature. `#scaled` is monotonic and measures 3.335%.
  `#random` is unchanged, so no other seeded result moves.
