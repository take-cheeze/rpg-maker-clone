- **bc2cpp**: a value constant whose every read the generated code resolves
  statically keeps no entry in its class's constant table; its value lives in
  a per-VM table the reads use (`CONST_BINDING_DROP`,
  `BC2CPP_DROP_CONST_BINDINGS=0` keeps every binding). mruby-lcf's ROM schema
  read is now a reviewed native read, so `CONST_DEF_ELIDE` runs for the engine
  too. Together they shrink the Wio Terminal image.
