- **Vehicles:** boarding now uses the correct trigger per vehicle type,
  matching a reference implementation's own vehicle-boarding handling, not
  independently confirmed against genuine RPG_RT under wine -- the Airship boards
  only by standing on its own tile, and a Boat/Ship boards only by facing
  it from an adjacent tile (the shore). Previously, a single generic check
  applied both triggers to every vehicle type: a placed, grounded Airship
  could be boarded merely by facing it from next to its tile (real RPG_RT
  does nothing there), and a Boat/Ship could symmetrically have been
  boarded by standing on its own tile rather than facing it from the
  shore. The Enter/Exit Vehicle event command shares this fix, since it
  drives the identical boarding path the action button uses.
