- **Sprites and viewports keep their common ivars in their own native payload**
  instead of a heap ivar table: `x`, `y`, `z`, `visible`, `bitmap`, `opacity`
  and `viewport` (and a viewport's `rect`, `ox`/`oy` and `tone`) live in slots
  of the object's RData, which mruby's ivar API reaches by name. Plane, Tilemap
  and Window do the same off the Wio. An ivar outside the slots (a flash, a
  tone on a sprite) still gets a table.
