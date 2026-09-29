- **bc2cpp** `NativeConstructSchema.scrape` skips native sources that never
  mention the class name before running its `(\w+)`-led regexp. Output is
  byte-identical.
