- **Change Party Member (10330) now refreshes the on-map hero sprite.** Adding
  or removing an actor can change who leads the party, and the map scene draws
  the hero from the leader's own CharSet, but only Change Sprite Association
  used to flag that graphic for reload. Nepheshel drives its whole companion
  mechanic through Change Party Member (5205 times), so a swap routinely left
  the map showing a companion who was no longer leading. `Game::Interpreter`
  now sets the same one-shot `actor_graphic_changed` request `Scene::Map`
  already drains every step, the way a reference implementation's own
  player-refresh handling runs on every party change, not only on an
  explicit sprite change (not independently confirmed against genuine
  RPG_RT under wine).
- **The title screen no longer crashes New Game if its title picture fails to
  load.** Every other asset loader in the RPG2000/2003 scene stack (the
  chipset, the charsets, both windowskin loaders, the game-over picture)
  degrades to a sane fallback on a missing or unreadable file; the title
  picture was the one exception, and an unhandled exception there aborted the
  whole engine before a frame was ever drawn — reading, from the outside, as a
  black screen on start. `Scene::Title` now loads it the same way
  `Scene::GameOver#gameover_bitmap` does: a blank background (as HideTitle
  already draws) instead of a crash.
