- **Boarding the Airship now doubles the party's per-frame walking speed,
  instead of moving at the same rate as on foot (or in a Boat/Ship, which
  are correctly unchanged).** Ported from a reference implementation, not
  independently confirmed against genuine RPG_RT under wine: the
  Airship carries a distinct, doubled move speed from Boat/Ship, which both
  keep the player's own default walking rate. An Airship ride previously
  crossed the map at exactly walking pace.
