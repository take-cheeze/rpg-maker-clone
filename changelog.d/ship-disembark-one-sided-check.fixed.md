- **Map:** disembarking a boat/ship now only tests the landing tile's own
  passability, matching RPG_RT -- previously it also tested the water tile
  being left and refused a landing blocked by another parked vehicle,
  neither of which the original game's own disembark check does.
