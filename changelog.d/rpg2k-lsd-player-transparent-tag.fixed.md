- **Fixed a real .lsd save bug that could leave the hero permanently
  invisible after Continue.** Set Transparent Flag's saved state was being
  read from an unrelated field that a genuine RPG_RT save often happens to
  set for its own reasons -- loading such a save could silently hide the
  player sprite for the rest of the game. It now round-trips through the
  correct field.
