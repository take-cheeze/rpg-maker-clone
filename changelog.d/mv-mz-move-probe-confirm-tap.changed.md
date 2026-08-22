- **MV/MZ move probe** (`--mv_move_test`/`--mz_move_test`, CI): now taps
  confirm to clear a blocking message window before it starts holding a
  direction, the way RGSS's own script-host driver already does. Previously
  it started walking the instant `Scene_Map` appeared, so a real game whose
  opening event shows text or choices the moment the map loads swallowed
  every movement key and reported "did not move" — not because the engine
  failed to walk the player, but because the probe never got a turn. The
  check is conditional on `$gameMessage.isBusy()`, so a project with no
  opening dialogue pays no extra time.
