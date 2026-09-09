- **Wio Terminal: folded 11 low-use-count helper methods into their call
  site(s).** `mrbc` has no method inliner of its own, so every `def` --
  however many times it's called -- always carries its own 10-byte irep
  header plus its own `iseq`/`pool`/`syms` blocks. Six methods
  (`bush_opacity`, `cell_origin`, `shadow_origin`, `anim_c`,
  `invalidate_items`, `drive_autostart_cascade`) have exactly one real
  engine caller; five more (`valid_move_freq`, `item_cured_states`,
  `numpad_direction`, `continuous?`, `frame_dir`) have 2-3, and were only
  kept after a real before/after compile confirmed duplicating their body
  at each call site still nets a byte reduction (several similarly-small
  candidates with a loop or branch chain of their own -- `lower_index`,
  `quads_from_quarters`, `kana_step_col` -- were hand-tested and rejected
  for costing *more* once duplicated). A new wio-only build step
  (`strip_wio_inline_helpers.rb`, the same Ripper-verified rewrite-a-copy
  mechanism ADR 119 already uses for stripping debug output) folds each
  into its call site(s) for wio's own compile only. The checked-in source,
  and every other target's build, keeps every definition exactly as-is --
  `scripts/rpg2k_render_check.rb`'s own regression checks call several of
  these by name, so deleting them outright would have broken real test
  coverage that has nothing to do with wio.
  Real whole-gem `mrbc --remove-lv` compile of the exact wio-shaped
  `rbfiles` list: 477,860 -> 477,133 bytes (727-byte reduction). See
  ADR 129.
