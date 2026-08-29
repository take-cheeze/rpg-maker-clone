- **Flash Sprite event command:** a Boat/Ship/Airship target now actually
  flashes the vehicle's sprite, instead of silently doing nothing. Matches
  RPG_RT's own character-resolution logic, ported from a reference
  implementation, not independently confirmed against genuine RPG_RT under
  wine, which resolves a vehicle target to the live vehicle object exactly
  like the player or a map
  event. A "wait for it to finish" request on a vehicle target now also
  holds for the flash's real configured duration, instead of releasing on
  the very next frame the way an unresolved target always did.
