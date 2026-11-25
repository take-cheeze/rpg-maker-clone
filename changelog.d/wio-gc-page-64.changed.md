- **Wio: the GC heap page holds 64 objects instead of 256.** The sweep frees
  a page once all its objects are dead, so after a map visit the Wio heap
  keeps less of its object pages: 7 KB less at the title and 18–61 KB less
  at the end of the measured map, battle and save runs.
