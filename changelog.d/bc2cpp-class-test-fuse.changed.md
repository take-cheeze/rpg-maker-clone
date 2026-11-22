- **bc2cpp** (`CLASS_TEST_FUSE`): a compiled guard that tests a receiver against a program class is now one
  indexed call (`bc2cpp_is_owner(M, v, slot)`) instead of a call to that class's cached-slot getter followed by
  `bc2cpp_class_is`, and the per-class getter functions are gone. The test and the slot lookup are the same as
  before. On the Wio build this cuts 37.8 KB of flash (a guard site goes from 16 to 10 bytes).
  `BC2CPP_CLASS_TEST_FUSE=0` turns it off.
