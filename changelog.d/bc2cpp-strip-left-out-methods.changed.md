- **bc2cpp removes left-out methods from the method tables.** An entry the
  registration proof leaves out (`static_dispatch_unregistered*.rb`) used to
  stay in its class's table as the gem's mrblib defined it: bytecode or an
  `attr_*` accessor. `bc2cpp_left_out` now removes that definition in every
  build except verify mode, which still registers its stub there. In the
  closed build, 2356 entries go, and `respond_to?` still answers for them
  through the `RESPOND_TO_PHANTOM` table.
