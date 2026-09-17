- `tools/bc2cpp/bc2cpp.rb` can now compile a block-carrying call site
  sitting INSIDE a method's own `rescue`-protected body --
  `RGSS::Profiler.section("...") { ... }`, `ary.each { ... }`, any of it --
  previously an honest `#error unhandled opcode BLOCK`/`SENDB` regardless
  of how simple the block was, and regardless of whether that exact
  method/block shape already worked fine OUTSIDE a rescue body.

  Found while investigating why `RPG2k#start_new_game`'s own
  `RGSS::Profiler.section("map.transition.load") { load_map map_id }`
  still `#error`'d even after `section` was added to
  `BLOCK_FALLBACK_UPVAR_SAFE_METHODS` specifically to unblock it (a prior
  round of this same file's own work): `emit_rescue_try_body` -- the
  function that extracts a `rescue`-protected region into its own
  standalone C++ function, run under `mrb_protect_error` -- translated
  its own body with a bare `compile_insn` call per instruction, with NONE
  of `compile_method`'s own top-level suppress/glue-at machinery
  (BLOCK_FALLBACK, the named `.each`/`.map`/... inliners, EXPLICIT_BLOCK_ARG,
  ...). A block-carrying call inside a `rescue` body was structurally
  invisible to every block-handling mechanism in this whole file, not
  merely unsupported by any one of them.

  Factored the shared BLOCK_FALLBACK/EXPLICIT_BLOCK_ARG recognize ->
  emit -> suppress pass out of `compile_method`'s own inline code into a
  new `emit_block_fallback_glue_pass` helper (one implementation, not two
  that could silently drift), reused by both: `compile_method`'s own
  top-level call scans the whole irep (unchanged behavior, its own
  `suppressed` set already excludes every rescue-body range wholesale,
  computed earlier in the same method, so it never double-claims a
  region this new pass also claims); `emit_rescue_try_body`'s own new
  call scans the SAME irep but filtered to the region's own `[begin_addr,
  end_addr]` range, into a fresh LOCAL `suppressed`/`glue_at` pair (a
  genuinely separate C++ function/scope, its own address-to-label
  mapping) -- and, since a nested region's own standalone cfunc is a
  real top-level function definition, illegal to nest inside another
  function's body, that nested pre-code is computed and emitted BEFORE
  the try-body function's own opening brace, not inside its instruction
  loop. Named inliners (`.each`/`.map`/`.times`/...) are NOT threaded
  through this same way yet -- still out of scope inside a rescue body,
  falls through to BLOCK_FALLBACK's own slower dynamic-dispatch catch-all
  instead of the faster inlined loop, a real remaining gap, just no
  longer a compile failure.

  Verified against the real whole-program diagnostic: compiled entry
  points 2213 -> 2233, method-level coverage 95.4% -> 96.3%, `#error
  unhandled opcode BLOCK` 75 -> 43, `SENDB` 68 -> 35, total `#error`
  markers 215 -> 148, `BLOCK_FALLBACK` sites 287 -> 320.
  `scripts/rpg2k_logic_check.rb` (1201 checks), `scripts/rpg2k_scene_check.rb`
  (1062 checks), and `scripts/lcf_testbed_check.rb` all still pass
  unchanged. Directly inspected real generated output: `RPG2k#start_new_game`
  now compiles fully clean, its own `RGSS::Profiler.section(...) {
  load_map map_id }` (an upvar capture of `map_id`) and `.each {
  |x| x.dispose if x.respond_to?(:dispose) }`-shaped block both correctly
  emitted as real `BLOCK_FALLBACK` functions ahead of the
  `rescue_try` function that references them. A real
  `g++ -std=c++17 -fsyntax-only` compile of the actual `SKIP_UNSUPPORTED=1`
  generated output confirms the exact same 17 pre-existing,
  already-documented, unrelated errors as immediately before this change
  (only their line numbers shifted) and zero new ones.
