- MV battle capture: a new `--mv_battle_test=<troopId>` flag drives the game
  into a test battle once it reaches the map (it implies the New Game
  auto-advance), pushing `Scene_Battle` against that troop. This lets a headless
  CI run exercise and capture the battle scene — its windows, battler layout and
  the HP/MP gauges (which draw through the new gradient `fillRect`) — without
  input. The MV sample smoke suite gains a battle step
  (`[MV] scene: … → Scene_Map → Scene_Battle`) that uploads the frame.
