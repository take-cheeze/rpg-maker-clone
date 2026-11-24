- The bc2cpp declarations of a battle's map scene, the map and vehicle
  worlds' scene and random number generator, a map scene's random number
  generator and Parallel Process list, and RPG2k's scene stack no longer
  allow nil. None of them is ever nil (the Parallel Process list and the
  scene stack are now set before any other call), so the compiled engine
  drops their nil tests and Wio flash shrinks.
