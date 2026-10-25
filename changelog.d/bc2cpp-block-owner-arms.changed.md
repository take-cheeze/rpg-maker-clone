- **bc2cpp**: owner calls that pass a block now get the same exact-class arms as plain ones. A receiver whose class
  is exactly a compiled engine class calls its `_impl` directly with the block, and anything else keeps the
  by-name owner call. In the closed build, 117 more owner calls (all `each`) get arms, for 238 in total.
