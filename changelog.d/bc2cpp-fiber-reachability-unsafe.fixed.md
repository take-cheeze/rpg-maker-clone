- `tools/bc2cpp/bc2cpp.rb` refuses to compile a method that directly calls
  `Fiber.yield`, and every method transitively reachable (via same-owner
  self-sends) from a `Fiber.new { block }` call site's own block body,
  down to and including every `Fiber.yield` it reaches -- falling back to
  the pre-existing `#error`/interpreted path, exactly like any other
  unsupported construct. This closes the gap the earlier `Fiber.new`-only
  fix left open: excluding just the construction site and its direct
  `Fiber.yield` callers was verified insufficient (the real 180-frame
  Optcarrot benchmark still crashed with `resuming dead fiber`, since the
  fiber body's own compiled `main_loop` still sat between its entry point
  and every yield). `tools/optcarrot_probe/compiled_run.rb` no longer
  excludes `Optcarrot::PPU` from `ONLY_OWNERS` -- confirmed end-to-end,
  not just via the static coverage report: the full 180-frame benchmark
  now completes with `Optcarrot::PPU` partially compiled (main_loop and
  its own ~36 reachable methods stay interpreted; the other ~38, including
  `sync`/`vsync`, now compile), checksum `59662` on all three runtimes,
  all 15 `scripts/bc2cpp_*_check.rb` static checks passing. Wall-clock
  impact not yet cleanly measured (the one run taken showed moderate
  machine contention); see `tools/optcarrot_probe/README.md` for the
  honest caveat.
