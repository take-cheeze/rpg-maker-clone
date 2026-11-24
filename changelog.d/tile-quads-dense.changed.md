- The tile drawing cache is built when a map is entered rather than during
  rendering, so it no longer keeps half-empty heap pages alive after map
  changes (less RAM held on the Wio Terminal).
