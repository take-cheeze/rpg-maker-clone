- `tools/bc2cpp/bc2cpp.rb`'s `BLOCK_FALLBACK` mechanism can now compile a
  block whose OWN body contains a real `rescue` clause --
  `cached_bitmap(cache, key) { Bitmap.new(...) rescue StandardError => e;
  ...; end }`, a real shape `RPG2k::Scene::Battle`/`RPG2k::Scene::Map`
  both ship (`#actor_battlecharset_bitmap`, `#battle_back_bitmap`, ...).
  Previously `RESCUE`/`RAISEIF`/`EXCEPT` sat on `BLOCK_FALLBACK_UNSAFE_OPS`
  unconditionally, rejecting the whole block-carrying call site outright
  the moment its own body used `rescue` anywhere, however small.

  `emit_proc_fallback_fn` now runs `recognize_rescue_regions`/
  `emit_rescue_try_body`/`emit_rescue_glue` -- the exact same real
  `mrb_protect_error`-based extraction `compile_method`'s own top-level
  loop already runs on an ordinary method body -- against the block's own
  irep too. `RESCUE`/`RAISEIF` were already unconditionally safe wherever
  they appear (real, always-correct translations regardless of whether
  the surrounding construct is ever recognized as extractable); only
  `EXCEPT` genuinely needed the recognizer's own extraction to mean
  anything, and a `rescue` shape `recognize_rescue_regions` itself
  declines to recognize (`retry`/`ensure`/a multi-class `rescue A, B`/
  nesting/a namespaced rescue class) still correctly leaves the honest
  `#error unhandled opcode EXCEPT` behind, unchanged.

  `emit_rescue_try_body`/`emit_rescue_glue` both gained an optional
  `extra_fields`/`extra_field_values` parameter (default `[]`, every
  pre-existing top-level caller's own behavior unchanged) so a rescue
  region nested inside a block body can thread that block's own captured
  upvar pointers into the extracted try-body function by name -- the same
  real variable name the enclosing block's own `_impl` function already
  has in scope, so `GETUPVAR`/`SETUPVAR`'s own `compile_insn` case needs
  no special-casing to find it there too.

  A real ordering constraint this composes around without conflict: the
  nested-BLOCK_FALLBACK pass (recursing into a NESTED block-carrying
  call) has to run BEFORE this level's own `@block_fallback_upvars`/
  `@block_fallback_active` are set (a recursive `emit_proc_fallback_fn`
  call manages its own copies independently and needs the ivars still
  unset when it starts), while the rescue-region pass's own
  `emit_rescue_try_body` needs those same ivars ALREADY set (its own
  `compile_insn` calls read them). Resolved by splitting "claim the
  address range" (pure, cheap, safe to do early via
  `recognize_rescue_regions` alone) from "emit the real extracted code"
  (deferred until after the ivars are set) -- the nested-BLOCK_FALLBACK
  pass's own recognizer, previously never checking whether a region's own
  address was already claimed, now does too, so a block-carrying call
  sitting inside a rescue clause is claimed exactly once, by the right
  pass.

  Verified against the real whole-program diagnostic: compiled entry
  points 2233 -> 2241, method-level coverage 96.3% -> 96.6%, `#error
  unhandled opcode SSENDB` 8 -> 0 (every real remaining site was this
  exact shape), `BLOCK` 43 -> 35, total `#error` markers 148 -> 132,
  `BLOCK_FALLBACK` sites 320 -> 328. `scripts/rpg2k_logic_check.rb`
  (1201 checks), `scripts/rpg2k_scene_check.rb` (1062 checks), and
  `scripts/lcf_testbed_check.rb` all still pass unchanged. Also added
  `cached_bitmap` to `BLOCK_FALLBACK_UPVAR_SAFE_METHODS` (both real
  definitions -- `RPG2k::Scene::Battle`/`RPG2k::Scene::Map` -- read
  directly: `return cache[key] if cache.key?(key); cache[key] = yield`,
  plain synchronous single yield, never stored), the call site this whole
  round was found investigating. Directly inspected real generated
  output: `RPG2k::Scene::Battle#actor_battlecharset_bitmap`'s own nested
  rescue-try function correctly receives both captured upvar pointers
  (`name`, the outer method's own argument, and the block's own local
  `key`) through its ctx struct, restores them by name, and the block's
  own `_impl` correctly invokes it under `mrb_protect_error`, matching
  the exact same shape the top-level case already used. A real
  `g++ -std=c++17 -fsyntax-only` compile of the actual `SKIP_UNSUPPORTED=1`
  generated output confirms the exact same 17 pre-existing,
  already-documented, unrelated errors as immediately before this change
  (only their line numbers shifted) and zero new ones.
