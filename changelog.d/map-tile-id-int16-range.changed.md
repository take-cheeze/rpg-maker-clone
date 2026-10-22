- **Map editor**: painting a tile id outside the LCF int16 range
  (-32768..32767) now raises a `RangeError` instead of storing it. Saving
  masked such an id to 16 bits and wrote a different tile. See ADR 0544.
