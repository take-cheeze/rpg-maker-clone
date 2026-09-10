- **Wio Terminal: folded 18 low-use-count helper methods into their call
  site(s).** `mrbc` has no method inliner of its own, so every `def` --
  however many times it's called -- always carries its own 10-byte irep
  header plus its own `iseq`/`pool`/`syms` blocks. Eleven have exactly one
  real engine caller and five more have 2-3 (kept only after a real
  before/after compile confirmed duplicating their body at each call site
  still nets a reduction -- several similarly-small candidates with a loop
  or branch chain of their own were hand-tested and rejected for costing
  *more* once duplicated). The remaining seven (`apply_tile_substitution`,
  `trunc_mod`, `do_open_main_menu`, `max_hp_cap`, `continue_available?`,
  `do_wait`, `draw_battle_row`) validate a rule for single-caller methods:
  safe and reliably net-positive to inline whenever the body has no
  loop/iterator keyword and no `return`/`yield`, even with `if`/`else` or a
  `rescue` modifier. A new wio-only build step
  (`strip_wio_inline_helpers.rb`, the same Ripper-verified rewrite-a-copy
  mechanism ADR 119 already uses for stripping debug output) folds each
  into its call site(s) for wio's own compile only. The checked-in source,
  and every other target's build, keeps every definition exactly as-is --
  `scripts/rpg2k_render_check.rb`'s own regression checks call several of
  these by name, so deleting them outright would have broken real test
  coverage that has nothing to do with wio.
  Real whole-gem `mrbc --remove-lv` compile of the exact wio-shaped
  `rbfiles` list: 477,860 -> 476,491 bytes (1,369-byte reduction). See
  ADR 129, which also documents a general-automation attempt (matching
  def parameters to call-site arguments, splicing bodies in mechanically
  across ~160 more candidates) that hit four rounds of real bugs and was
  abandoned in favor of the smaller, individually-verified set above.
