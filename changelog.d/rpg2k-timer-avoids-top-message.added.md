- **The on-screen timer now slides down to the bottom edge outside of
  battle whenever the last message window resolved to the top of the
  screen, so the two never overlap.** Ported from a reference implementation,
  not independently confirmed against genuine RPG_RT under wine: the check
  is against the message
  window's last *resolved* position -- itself downstream of RPG2000's
  dynamic avoid-the-hero repositioning when the position is not pinned --
  and it stays sticky even after that message closes, only resetting on a
  genuine new map visit (Teleport/Transfer Player), not a mere return from
  a pushed menu/battle scene.
