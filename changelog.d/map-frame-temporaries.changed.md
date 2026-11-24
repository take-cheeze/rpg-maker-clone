- The map scene makes far fewer temporary objects per frame (event movement,
  page checks, draw order, blit rectangles, bitmap-cache lookups), so the
  garbage collector runs less often on the Wio Terminal.
