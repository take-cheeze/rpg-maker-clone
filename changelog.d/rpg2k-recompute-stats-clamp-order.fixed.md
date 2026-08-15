- **An actor's effective Attack/Defence/Spirit/Agility/max HP/max SP now
  clamp curve + Change Parameters mod + equipment together, as one combined
  total, instead of clamping the curve+mod part alone and then clamping
  again after adding equipment.** Confirmed against EasyRPG Player's source:
  `Game_Actor::GetBaseAtk` and its siblings sum all three sources in one
  expression and clamp exactly once. The old double clamp let equipment
  bypass an active floor: a stat debuffed low enough to floor its display at
  1 would let a newly-equipped item's *entire* bonus land back on top of
  that floor, instead of on top of the real (still deeply negative) total
  the debuff left behind — silently undoing an active debuff just by
  re-equipping.
