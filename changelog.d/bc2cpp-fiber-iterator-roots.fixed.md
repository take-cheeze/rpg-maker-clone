- A compiled Fiber root that sends `Integer#step` (or any iterator) a block reaching `Fiber.yield` through its helper
  methods now compiles the iterator as a step. Since the block stages the block stayed a block but `Integer#step` was
  still called from C, so optcarrot's `PPU#main_loop` died with a `FiberError` and a wrong checksum. The optcarrot
  probe builds again (its scan now sees `OptcarrotProbe` and the gems' Ruby constants, CONST_RESOLVE) and
  `optcarrot_probe_scan_check.rb` keeps its scan in CI.
