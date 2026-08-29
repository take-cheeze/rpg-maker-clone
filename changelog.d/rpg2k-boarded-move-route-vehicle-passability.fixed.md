- **A boarded hero's own Set Move Route commands (Dash, Jump, plain
  movement, all alike) now respect the ridden boat/ship/airship's own
  passability, instead of on-foot chipset passability.** Ported from a
  reference implementation's player-movement code, not independently
  confirmed against genuine RPG_RT under wine: real RPG_RT
  unconditionally delegates to the ridden vehicle's own passability for
  *all* player movement, input-driven or move-route-driven alike, once
  boarded. This engine already did that for ordinary input movement, but a
  move-route-driven hero always checked plain on-foot passability
  regardless of being boarded — letting a forced route sail/fly through
  terrain the ridden vehicle itself could never cross, or stall on terrain
  it could freely cross.
