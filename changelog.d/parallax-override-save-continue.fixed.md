- **Saves:** a live Change Parallax Background override now survives a
  real Save/Continue, matching RPG_RT's `SaveMapInfo.parallax_*` fields --
  it previously reverted to the map's own panorama the moment a genuine
  `.lsd` save was reloaded, even though it correctly reset on an actual
  map change.
