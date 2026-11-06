- The bc2cpp closed world resolves a native class whose superclass is passed as a local variable, so mruby-io's
  `File < IO` lets `File.open` and the other inherited `IO` class methods resolve to `IO.singleton`. Covered by
  `scripts/bc2cpp/native_class_supers_check.rb`.
