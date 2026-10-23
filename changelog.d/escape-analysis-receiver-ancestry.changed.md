- **Escape analysis** (`bc2cpp`) no longer treats a call as a possible native just because some class defines a
  native method of that name. When the receiver's exact class is known, its ancestry is checked with the native
  owner map, so user accessors such as `attr_reader :x` confine. A `new` whose constructor keeps `self`, or whose
  constructor cannot be resolved, now escapes; this only affects the escape report.
