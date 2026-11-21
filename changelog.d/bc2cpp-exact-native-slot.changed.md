- **bc2cpp**: a send whose receiver is proven to be exactly one class and whose
  method is a C function now calls it through a per-method slot instead of an
  owner call. An implicit-self `push` whose self is not an Array calls the
  class's own method directly. This removes 73 owner calls from the closed
  build (1230 to 1157) and about 1.3 KB of flash on the Wio build.
