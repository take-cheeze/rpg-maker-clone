- **bc2cpp**: the closed build no longer emits compiled class-body units or calls them from `gem_init`. The VM runs each
  class body once; the compiled copy ran it a second time.
