- **Save/Continue export:** RPG_RT restores the camera from the save instead
  of deriving it from the hero, so a save this engine exported for a genuine
  RPG_RT or EasyRPG to load now carries the camera's top-left pixel (chunk
  111 fields 1/2) — previously it was never written, so loading one of our
  saves in the real runtime rendered the map's top-left corner instead of
  the hero-centred view.
