- **`mruby-rgss/mrbgem.rake`'s own `wio_strip_bc2cpp_stubs` call now
  strips all 14 of `mruby-rgss-compiled`'s real registered owners**
  (`tools/bc2cpp/compiled_gems.rb`), not just the original 4
  (`RGSS::Sprite`/`RGSS::Window`/`RGSS::Audio.singleton`/`RGSS::
  ErrorReport.singleton`). Ten new owners join: `RGSS::Plane`,
  `RGSS::Tilemap`, `RGSS::Bitmap`, `RGSS::Bitmap.singleton`,
  `RGSS.singleton`, `RGSS::Input.singleton`, `RGSS::Graphics.singleton`,
  `RGSS::Font.singleton`, `RGSS::ErrorReport::Tee`, and `Array` — 34 real
  registered methods total (real `wio_registered_methods.rb` ground
  truth, cross-checked against the raw bc2cpp.rb diagnostic directly).
  `RGSS::Input.singleton` specifically got its own from-scratch
  re-verification (an earlier round's own comment had flagged a real
  `mrb_funcall(..., "press"/"release", ...)` call site into it as "not a
  gem-init-time hazard" but never independently re-checked): traced the
  real call graph end to end — all four platform input backends'
  `rgss_*_poll` functions are only ever reached from `RGSS::Input._poll`,
  itself only reached from `RGSS::Input.update`'s own Ruby body, itself
  only ever called from a running game's own per-frame scene loop — never
  from any gem's own `gem_init`/`gem_final`. Also found and ruled out one
  more real, runtime-only `mrb_funcall(..., "warn_stub", ...)` call site
  into `RGSS.singleton` (reached only through `Graphics.snap_to_bitmap`'s
  native failure path, itself only ever called from gameplay/scene-
  transition/CLI-probe code). Companion-statement, `DIRECT_CONSTRUCT_
  TARGETS`/`NATIVE_ARG_TARGETS`, and byte-for-byte regression checks (the
  pre-existing 4 owners strip identically before and after this change)
  all passed — see `mruby-rgss/mrbgem.rake`'s own updated comment for the
  full per-owner writeup. Real `mrbc -g` measurement (matching this
  build's own `enable_debug`): the three affected files' combined size
  drops from 37,463 to 24,707 bytes (a 12,756-byte, 34.0%, reduction) on
  top of the original round's own measured effect. With this round,
  `mruby-rgss`'s own `owners:` list matches `mruby-rgss-compiled`'s full
  real registered-owner set exactly — no further owner-scaling candidate
  remains for this gem.
