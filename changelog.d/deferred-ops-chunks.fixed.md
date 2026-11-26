- **Wio:** a deferred bitmap keeps its recorded draws in 4 KB blocks instead of
  one array that doubles as it grows, so a map layer's draw list (about 2400
  draws, 38 KB on Nepheshel's first map) no longer needs a 32 or 64 KB block,
  or the old and the new array at once while it grows.
