- **Field item menu:** using a switch item (database item type 10) now
  flips its switch, consumes one, and closes the whole menu stack at once —
  the same as a special item invoking Escape or Teleport — instead of
  dropping back into the (rebuilt) item list with a "Switch turned on."
  message. A use that consumed nothing still reports "It had no effect." and
  leaves the menu open. Covered by new checks in `scripts/rpg2k_scene_check.rb`.
