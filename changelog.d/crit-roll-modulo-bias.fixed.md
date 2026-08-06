- **A critical chance is paid out at the rate it states.** Moving criticals to a
  basis-point probability left the roll drawing through `Rng#random(10000)`, and
  the generator's period is prime — so `next_int % 10000` leaves its lowest 5537
  values over-represented, which is exactly the range a roll-under-a-small-
  threshold test reads. Measured through the real `Battle#critical?`, every crit
  chance fired about **7% more often** than its number said: a 333 bp chance
  landing 3.562% instead of 3.330%, a 3333 bp chance 35.600% instead of 33.330%,
  the same relative error at every threshold tested. The roll now draws through a
  new **`Rng#scaled`**, which multiplies across the period rather than taking a
  modulus of it; being monotonic it spreads the unavoidable unevenness across the
  range instead of piling it under the threshold, and the same measurement reads
  3.335% and 33.338%.

  `Rng#random` is deliberately unchanged: every other caller passes a small `n`
  where the same bias is a handful of draws in thousands, and touching it would
  reshuffle every seeded result in the project for no gain.

  Over every troop in both test beds the correction takes Nepheshel from 156
  criticals to 141 and mtf-meido-action from 27 to 18 — the overshoot being paid
  back — with Nepheshel's record going from 126 wins to 124 in its 157 fights.
