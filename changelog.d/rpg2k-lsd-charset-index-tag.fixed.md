- **A Change Actor Sprite / Change Vehicle Graphic override's character-sheet
  index is now written to, and read from, the correct field of a real .lsd
  save.** It used to land on the field liblcf actually uses for unrelated
  per-frame bookkeeping, which only surfaced against a genuine third-party
  save (or a save this engine exports being opened elsewhere) since this
  engine's own Save/Continue used the same wrong field consistently on both
  sides.
