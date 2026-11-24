- **Fewer GC heap pages on a map**: the common event records are made after the
  database scan instead of one per row in between its garbage, so they no
  longer hold a mostly empty GC heap page each alive (about 16 KB on
  Nepheshel's Wio build).
