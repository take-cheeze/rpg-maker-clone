- **Saves:** a shown picture (Show Picture) now survives a real
  Save/Continue -- `Game::State#to_lsd` previously never wrote chunk 103
  at all, confirmed against genuine RPG_RT.exe to round-trip it
  unconditionally on every save, holding all 50 picture slots whether
  or not each one is actually in use; a picture up during a cutscene
  used to silently vanish the instant this engine's own Save/Continue
  ran.
