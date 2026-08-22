- **The F9 debug menu's Map page can now browse any map id, not only the
  player's own current one.** Up/Down step the selected id by one and L/R by
  ten — the same convention its Animation page already uses for an animation
  id — and C opens that id's Map Editor: the player's real live map when
  it's the one selected (unchanged from before), or a different map loaded
  fresh off disk otherwise, so a project can be browsed and edited one map at
  a time without first walking the player there. A map opened this way shows
  no player marker and centres on its own middle tile rather than the live
  player's position, since the player isn't actually standing on it; edits
  still save back to that map's own `.lmu` file as normal.
