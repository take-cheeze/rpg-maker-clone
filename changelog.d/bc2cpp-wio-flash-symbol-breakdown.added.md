- **Added a symbol-level breakdown to docs/adr/0143's real `wio_rgss_boot`
  `RPGMAKER_BC2CPP=1` flash measurement.** Same build, re-verified non-stale
  the same way (`register.o`'s real symbol counts, per-gem `.text` sizes,
  and the link's exact overflow figure all match ADR 0143's own numbers
  bit-for-bit). A `firmware.map` per-input-section breakdown finds the
  image's size dominated by a long tail of individually modest
  `mruby-rpg2k-compiled` generated methods rather than a few outsized
  symbols, once a dozen or so genuinely large non-bc2cpp tables/blobs
  (Unicode/CP932 conversion tables, mruby's own presym symbol tables, a
  merged UI string pool) are accounted for; `Game::Interpreter#execute` and
  `Game::MoveRoute#execute` are the two largest individual compiled
  functions in the whole firmware. See
  `docs/adr/0143-bc2cpp-real-wio-flash-ram-remeasurement-at-full-scope.md`'s
  own addendum for the full top-30 whole-firmware list and each compiled
  gem's own top-15 breakdown.
