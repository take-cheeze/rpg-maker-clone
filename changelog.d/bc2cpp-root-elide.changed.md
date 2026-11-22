- **bc2cpp** (3rd/nfcxx bump): the compiled code drops the GC root of a value
  an ivar store replaces when the slot can only ever hold `nil`, `true`,
  `false` or a Symbol. It roots a run of slot stores with one call, and passes
  the value first to the shared root helper. The Wio image is 8.8 KB smaller.
