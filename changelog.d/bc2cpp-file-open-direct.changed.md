- **bc2cpp: `File.open(path) { |f| ... }` calls mruby-io's compiled `IO.open`
  directly.** `declarations.rbs#core_hierarchy` now declares `File < IO`, so the
  class-method lookup for a block send reaches `IO.open`. The constant receiver
  is also read when written `::File` or when the send sits in a `rescue` range.
  All seven `File.open { }` sites of the engine and core now call the compiled
  body at the root context, and keep the send for a Fiber.
