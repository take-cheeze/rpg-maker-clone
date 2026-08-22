- **Saves:** a shown picture (Show Picture) now survives a real
  Save/Continue -- `Game::State#to_lsd` previously never wrote chunk 103
  at all, matching RPG_RT's `Scene_Save::Prepare`/`Player::LoadSavegame`,
  which round-trip it unconditionally on every save; a picture up during
  a cutscene used to silently vanish the instant this engine's own
  Save/Continue ran.
