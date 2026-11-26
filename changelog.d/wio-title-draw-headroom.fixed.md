- **Wio Terminal**: the title screen no longer runs out of memory after a few
  hundred frames on the 192 KB board. Garbage the GC had not reached yet filled
  the heap, and the frame's draw, which cannot collect, then failed. Each frame
  now runs a full GC before the draw when 4 KB of the heap is not free.
