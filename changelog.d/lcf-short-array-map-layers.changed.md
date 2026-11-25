- **RPG2000/2003** map layers (`.lmu` chunks 71/72) are now read into
  `LCF::ShortArray`, a native table that stores 2 bytes per tile. They used to
  be an Array of Integers, which takes a word per tile plus growth slack. On a
  141x100 map this keeps about 70 KB less heap, which matters on the Wio
  Terminal. Writing a tile id outside int16 raises `RangeError`, and writing
  outside the map raises `IndexError`.
