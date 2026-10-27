- **bc2cpp** (`ATTR_READER_INLINE`): a devirtualized call to the synthesized `attr_reader` of an embedded ivar
  now reads the struct field at the call site. Before, it called the reader, which usually sits in another
  shard. Its exact-class guard also tests the object's own class pointer before falling back to `mrb_obj_class`.
  The guard and the read match the old call exactly, and subclass overrides, reopened readers, nil and other-class
  receivers keep their paths. In the optcarrot probe, `CPU#run`'s per-instruction `@conf.loglevel` test is now a
  load and a compare: the frame loop falls from 23.83M to 23.67M instructions per frame (−0.70 %), and startup
  is unchanged.
  `BC2CPP_ATTR_READER_INLINE=0` turns it off. See `docs/bc2cpp-attr-reader-inline.md`; the new check is
  `scripts/bc2cpp/attr_reader_inline_check.rb`.
