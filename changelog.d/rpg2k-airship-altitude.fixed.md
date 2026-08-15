- **The airship now floats a real, full 16px tile above its ground shadow,
  instead of a wrong half-tile 8px.** Confirmed against EasyRPG Player's
  source (`Game_Vehicle::GetAltitude()`): the real steady-state (fully
  airborne) altitude is a full tile, `256 / (256 / 16) = 16` with RPG_RT's
  own real constants.
