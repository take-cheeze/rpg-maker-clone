- bc2cpp now uses guarded native conversions for zero-argument `to_i` on
  Integer, Float and String values, retaining Ruby dispatch for other types.
