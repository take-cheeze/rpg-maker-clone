- **Wio Terminal: fixed two real crash bugs from ADR 131's own method
  inlining -- `try_open_debug_menu` and `rebuild_chipset` were inlined away
  while a `public :symbol` declaration elsewhere in the same class still
  referenced them, raising an uncaught `NoMethodError` the moment gem init
  tried to execute that declaration.** Present in every wio build since
  ADR 131, never caught before now because nothing had ever actually
  booted `wio_rgss_boot` far enough to reach it (blocked first by real
  flash overflow, then by docs/adr/0135's RAM-exhaustion bug). A real
  `mrbc` compile succeeding does not prove a build's bytecode is safe to
  run -- `public :anything` is syntactically valid regardless of whether
  the method exists. Both methods restored as real methods in the wio
  build; searched every other inlined candidate against the same pattern
  (a bare symbol in a `public`/`private`/`protected` list, not just
  ordinary `.method_name` calls) and found no others. See docs/adr/0136.
- **Wio Terminal: measured how much RAM `wio_rgss_boot` actually needs to
  finish booting -- 296,152 bytes, against the real board's 196,608 (192
  KB), a 99,544-byte shortfall.** With both bugs above fixed and RAM
  temporarily widened past the real board's limit (a diagnostic-only
  Renode/linker-script setup, never a real hardware config), `setup()` now
  runs to real completion for the first time. The dominant cost (261,400
  of the 296,152 bytes) is heap growth during gem initialization -- loading
  the RGSS/mruby-lcf/mruby-rpg2k class and method tables as live objects,
  confirming docs/adr/0135's finding that this, not stack depth or static
  data, is the real blocker. See docs/adr/0136.
