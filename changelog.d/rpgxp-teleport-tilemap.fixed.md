- RPG Maker **XP**: a **Transfer Player** now rebuilds the map's ground. The
  scene's `Tilemap` was created once on entry and never replaced, so after a
  teleport the new map's events and the party walked over the *previous* map's
  tiles — black, when the previous map was an empty opening map, which is
  exactly how Pray for You starts. RMXP disposes and rebuilds the whole
  `Spriteset_Map` on a transfer; `perform_teleport` now does the same. Only a
  game with more than one map could show this, which is why the single-map test
  bed never did.
