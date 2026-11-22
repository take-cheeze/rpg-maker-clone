- **bc2cpp** builds a String literal that is only read by an audited native
  (`RGSS::Profiler.section`, `Array#pack`, `String#unpack`) as a frame-local
  String over the literal's bytes instead of a heap String, when the escape
  analysis proves it never leaves the method. `BC2CPP_STACK_STRINGS=0` turns it
  off. The audit of those natives (`NATIVE_ARG_OK`) now also holds in the
  shipped build, which names its native sources by relative path.
