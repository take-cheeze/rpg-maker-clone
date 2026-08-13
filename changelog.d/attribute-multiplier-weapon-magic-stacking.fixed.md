- **An attack naming both a weapon-type and a magic-type Attribute now
  multiplies the two rates as fractions (200%×50%=100%)**, matching
  yado.tk, instead of picking a single strongest-of-all-ids rate the way
  `Game::Battle#attr_multiplier` did before. Same-type stacking is
  unchanged: the strongest rate within each type bucket still wins, and a
  type with no ids in the attack contributes 100% (unaffected), so a
  single-type attack behaves exactly as before.
