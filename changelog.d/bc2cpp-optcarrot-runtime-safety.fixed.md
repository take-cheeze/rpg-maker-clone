- bc2cpp generated C++ now includes `mruby/numeric.h` for its integer and
  float conversion helpers. C function backed blocks also match Ruby's
  lenient argument handling and multi-parameter Array destructuring, and
  ivar embedding is disabled across inheritance chains when separate
  structs would overwrite an object's single data pointer.
