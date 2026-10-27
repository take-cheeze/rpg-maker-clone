- **bc2cpp**: a hit in the per-site constant and class caches (`bc2cpp_cconst_N`, `bc2cpp_mcnst_N`,
  `bc2cpp_owner_class_N`) is now an inline slot load without an `mrb_state` compare. The compiled gems clear the
  slots at `gem_init` as well as `gem_final` (the game's deferred gem init never runs `gem_final`), and a fill stops
  with `mrb_bug` if a second live VM reaches it. On the Nepheshel trace host the 1-frame load fell from 379.1 M to
  377.4 M instructions and the 1,200-frame run spent 13.7 M (0.76%) fewer outside LVGL. See
  `docs/bc2cpp-constant-lookup.md` (VM_CACHE_LIFETIME).
