- MV real-game play smoke test: a new CI step drives the downloaded RPG Maker
  MV test bed (KinoAR/Lunatic-Core) past the title into actual play — New Game →
  map, then holds a direction and logs the player's start/end tile
  (`[MV-MOVE] ... moved=<bool>`) and captures a frame. The existing boot smoke
  only reached the title; this exercises the fuller real game's
  map/movement/render path (a real database, autotiles and character sheet the
  minimal `data/mv-sample` can't cover). Non-blocking, like the other MV smokes.
