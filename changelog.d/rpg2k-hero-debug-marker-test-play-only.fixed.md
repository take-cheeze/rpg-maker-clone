- **The hero's missing-graphic debug marker is now Test-Play-only.** When the
  party leader's CharSet graphic fails to load, `Scene::Map` used to paint a
  solid yellow block over the hero as a fallback marker regardless of how the
  game was launched — visible in a released game exactly like it was during
  development. The marker's alpha now follows `Game#test_play`: full opacity
  under Test Play (TestPlay/Game.ini `Test=1`/`--test_play`), fully
  transparent otherwise, so a released game with a missing hero graphic
  renders nothing there, matching RPG_RT.
