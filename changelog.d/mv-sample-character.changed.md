- MV sample player is now visible. `scripts/gen-mv-sample.py` authors a tiny
  hand-encoded walk sheet (`img/characters/$Hero.png` — a 3×4 single-character
  sheet) and points the actor's `characterName` at it, so the hero renders and
  animates on the map instead of being invisible. This exercises the engine's
  `Sprite_Character` path (character-sheet frame selection by direction and walk
  pattern) end to end, and makes the movement/sample smoke screenshots show an
  actual character on the tiled room.
