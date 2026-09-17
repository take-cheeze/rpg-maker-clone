- `tools/bc2cpp/bc2cpp.rb`'s `BLOCK_FALLBACK_UPVAR_SAFE_METHODS` allowlist
  (gates pointer-based upvar capture to call sites confirmed synchronous --
  see that constant's own comment) grows by nine more real, individually
  body-read-and-verified names, found by re-running the real whole-program
  "what's still blocking BLOCK/SENDB/SSENDB" sweep after the last round of
  BLOCK_FALLBACK work: `page_field`, `section`, `open`, `new`, `reduce`,
  `inject`, `each_with_object`, `downto`, `auto_battle_best_target`.

  Each verified the same way every existing entry was -- real body read
  directly, not assumed from its name:
  - `page_field` (mruby-rpg2k/mrblib/scene/map.rb): `yield rescue
    StandardError => e; ...; default; end` -- one synchronous yield; its
    OWN `rescue StandardError` is separate bytecode from the block this
    allowlist gates (same "a callee's own unrelated rescue/ensure can't
    swallow a foreign `bc2cpp_block_break`/`bc2cpp_method_return`, MRB_CATCH
    is type-specific" argument `loop`'s own citation already established).
  - `section` (mruby-rgss/src/profiler.cxx): `mrb_yield_argv` called
    exactly once, optionally timed around, never stored.
  - `open` (3rd/mruby/mrbgems/mruby-io/mrblib/io.rb's `IO.open`, inherited
    by `File.open` -- confirmed neither mruby-io's nor mruby-lcf's own
    `File` reopens `self.open`): `begin yield io ensure io.close ... end`
    -- same "callee's own unrelated ensure" argument as `page_field`.
  - `new` (3rd/mruby/src/array.c's `mrb_ary_init`, real `Array.new(n) { |i|
    ... }`): a plain loop calling `mrb_yield` once per index, never
    stored. Gated by name alone, so this trusts EVERY upvar-capturing
    `.new` call site to be `Array.new` -- confirmed safe by a real
    whole-program grep finding no bytecode `initialize` (mruby-rgss/
    mruby-rpg2k/mruby-lcf's own mrblib) or native constructor (mruby-rgss/
    src/*.cxx) declaring a block parameter anywhere in this closed world.
  - `reduce`/`inject` (3rd/mruby/mrblib/enum.rb, aliased): `self.each {
    ... }`-based, synchronous, no bytecode override anywhere in this
    closed world. `recognize_accum_regions`'s own dedicated inline emitter
    already handles the common case (a receiver PROVEN Array); this only
    matters when that gate misses (e.g. an ivar not yet CLASS_HINT-proven
    Array) -- the same catch-all relationship BLOCK_FALLBACK already has
    with every other named inliner.
  - `each_with_object` (mruby-enum-ext/mrblib/enum.rb): `self.each {|*val|
    block.call(val.__svalue, obj)}` -- same shape/conclusion as reduce.
  - `downto` (3rd/mruby/mrblib/numeric.rb): plain synchronous `while`
    loop, core Integer method.
  - `auto_battle_best_target` (mruby-rpg2k/mrblib/game/battle.rb, this
    program's own domain method): `targets.each do |t| r = yield t; ...
    end; best` -- plain synchronous, real body read directly.

  Verified against the real whole-program diagnostic: compiled entry
  points 2166 -> 2198, method-level coverage 93.4% -> 94.8%, `#error
  unhandled opcode BLOCK` 112 -> 75, `SENDB` 99 -> 80, `SSENDB` 26 -> 8,
  total `#error` markers 311 -> 235, `BLOCK_FALLBACK` sites 250 -> 287.
  `scripts/rpg2k_logic_check.rb` (1201 checks), `scripts/rpg2k_scene_check.rb`
  (1062 checks), and `scripts/lcf_testbed_check.rb` all still pass
  unchanged. Directly inspected real generated output:
  `RPG2k::Scene::Map#page_trigger`'s own `page_field(:trigger, 0) {
  page.trigger }`, correctly capturing `page` (the method's own mandatory
  argument) via pointer into the new `BLOCK_FALLBACK` region. A real
  `g++ -std=c++17 -fsyntax-only` compile of the actual `SKIP_UNSUPPORTED=1`
  generated output confirms the exact same 17 pre-existing,
  already-documented, unrelated errors as immediately before this change
  (only their line numbers shifted) and zero new ones.
