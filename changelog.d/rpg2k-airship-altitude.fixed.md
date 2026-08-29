- **The airship now floats a real, full 16px tile above its ground shadow,
  instead of a wrong half-tile 8px.** Ported from a reference implementation's
  altitude formula, not independently confirmed against genuine RPG_RT
  under wine: the real steady-state (fully
  airborne) altitude is a full tile, `256 / (256 / 16) = 16` with RPG_RT's
  own real constants.
