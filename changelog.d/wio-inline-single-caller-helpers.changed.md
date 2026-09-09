- **Wio Terminal: folded 6 single-real-caller helper methods into their call
  site.** `mrbc` has no method inliner of its own, so every `def` -- however
  many times it's called -- always carries its own 10-byte irep header plus
  its own `iseq`/`pool`/`syms` blocks. `bush_opacity`, `cell_origin`,
  `shadow_origin`, `anim_c`, `invalidate_items` and `drive_autostart_cascade`
  each have exactly one real engine caller; a new wio-only build step
  (`strip_wio_inline_helpers.rb`, the same Ripper-verified rewrite-a-copy
  mechanism ADR 119 already uses for stripping debug output) folds each into
  that call site for wio's own compile only. The checked-in source, and
  every other target's build, keeps every definition exactly as-is --
  `scripts/rpg2k_render_check.rb`'s own regression checks call several of
  these by name, so deleting them outright would have broken real test
  coverage that has nothing to do with wio.
  Real whole-gem `mrbc --remove-lv` compile of the exact wio-shaped
  `rbfiles` list: 477,860 -> 477,395 bytes (465-byte reduction). See
  ADR 129.
