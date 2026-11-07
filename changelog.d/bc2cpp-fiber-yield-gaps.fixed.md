- **bc2cpp**: a Fiber body can call a blockless iterator (`ary.each`, `e = x.each; e.next`), `Kernel#loop` and
  `Hash#fetch_values` with a yielding block, and `Fiber.yield` from a block a C iterator runs raises mruby-fiber's
  "can't cross C function boundary".
