- **LCF** files keep less heap. Every 1-byte or empty chunk, and every empty
  event or move command string, is now one shared frozen String. A row of a
  table read from memory is now a slice of the table's bytes instead of a
  copy. On the Wio Terminal this leaves about 200 KB less live heap on
  Nepheshel's map 355 and about 50 KB less on map 120. Mutating one of these
  strings in place now raises `FrozenError`.
