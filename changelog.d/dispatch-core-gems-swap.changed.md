- **bc2cpp**: `tools/bc2cpp/static_dispatch_registrations.rb` takes
  `--core-gems=a,b,c`, the build's own core mrblib gems, in place of the
  closed world's fixed `nil`. The default output is unchanged. A custom list
  prints its result and refuses `--write`, so it cannot overwrite the closed
  table.
