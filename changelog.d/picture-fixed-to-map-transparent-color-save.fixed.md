- **Pictures:** A picture shown with "fixed to map position" (so it scrolls
  with the camera instead of the screen) or "not affected by transparent
  color" now keeps that setting across a Save/Continue. Previously neither
  flag was saved at all, so loading a save made while such a picture was on
  screen silently reverted it to the opposite behavior -- a map-scrolling
  picture would jump to being screen-fixed, or a picture exempted from the
  transparent color would start honoring it again, the moment the save was
  loaded.
