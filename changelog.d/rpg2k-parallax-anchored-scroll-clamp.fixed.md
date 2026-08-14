- **A non-looping parallax background wider than the map's own scroll room
  no longer over-pans past what the map's limited camera range should ever
  reveal.** Confirmed against EasyRPG Player's source
  (`Game_Map::Parallax::ResetPositionX`): the image's interpolation span is
  `min(the map's own scrollable excess, the image's own excess)`, not
  always the image's full excess. Invisible whenever an image's excess
  happens to be no larger than the map's own, but a real divergence once a
  panorama image is wider, relative to its own excess, than the map it
  sits on has room to scroll.
