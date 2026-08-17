- The RGSS runtime can now be tested under plain CRuby, with no mruby build:
  `scripts/rgss_cruby_compat.rb` stands in for the native half of mruby-rgss
  (the value types with RGSS Marshal, a pixel-capable Bitmap whose blit
  arithmetic mirrors `src/lib.cxx`, the display objects, Graphics/Audio/Input/
  Profiler, and PNG/XYZ decode including the tolerant-inflate fallback), and
  `scripts/rgss_cruby_test_check.rb` runs the real `mruby-rgss/test/test.rb`
  through it — 87 assertions guarding the RGSS behavioural contract. Registered
  in the `ruby-checks` CI job and the coverage reporter, which lifts
  `mruby-rgss` from 0% to ~52% host-side line coverage.
