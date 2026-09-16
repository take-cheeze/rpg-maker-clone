- `tools/bc2cpp/bc2cpp.rb` can now inline three more block-taking method
  names, each following the same recognizer/emitter/wiring shape the
  existing eight already use:

  - `Array#each_index` (new `recognize_each_index_regions`/
    `emit_each_index_inline`) -- real `#each_index`
    (`3rd/mruby/mrblib/array.rb`) yields the loop INDEX only (a fixnum),
    never an element, with a live `length` re-check every pass; the new
    emitter clones `emit_each_inline`'s own live-`RARRAY_LEN` loop but
    binds the block's parameter to `mrb_fixnum_value(i)` instead of an
    `mrb_ary_ref`/`bc2cpp_ary_entry` fetch, with no `with_element_hint`
    (the value is always Integer, already known to codegen without one
    -- the same reasoning `emit_collect_inline`'s own `each_with_index`
    index parameter already uses). 13 real call sites across
    `mruby-rpg2k/mrblib` (`Game::Actor#defensive_attribute_ids`/
    `#weapon_attributes`/several other id-bitset scans in `game.rb`,
    `Scene::Battle`'s shake-timer scan, `Game::LsdIO`'s save/load id
    scans, `Game::Battle`'s flee scan) plus 2 in
    `mruby-rgss/mrblib/lib.rb` (`RGSS::Input`'s own `@triggered`/
    `@pressed` key scans).
  - `Hash#each_key` (new `recognize_each_key_regions`/
    `emit_each_key_inline`) -- real `#each_key`
    (`3rd/mruby/mrblib/hash.rb`, `self.keys.each {|k| block.call(k)}`)
    snapshots `keys` once (real `mrb_hash_keys`, `MRB_API`,
    `mruby/hash.h`) and yields only the key; the new emitter clones
    `emit_hash_each_inline`'s own snapshot loop but takes no
    `mrb_hash_values` snapshot at all and binds only one register per
    iteration. 1 real call site: `Scene_Map`'s own LRU-eviction scan
    (`mruby-rpg2k/mrblib/scene/map.rb`,
    `@entries.each_key { |k| oldest_key = k; break }`).
  - `filter_map` (extended `COLLECT_BLOCK_METHODS`/`emit_collect_inline`,
    no new recognizer needed -- same "one recognizer, several related
    method names" shape `recognize_collect_regions` already uses for
    `map`/`select`/`reject`/`find`/`each_with_index`). Confirmed present
    in this closed world despite not being a native Array method (no
    `MRB_SYM(filter_map)` in `3rd/mruby/src/array.c`) -- it is
    `Enumerable#filter_map`
    (`3rd/mruby/mrbgems/mruby-enum-ext/mrblib/enum.rb`, mixed into
    Array; `mruby-enum-ext` is a real dependency of both
    `mruby-rpg2k` and `mruby-wolf`'s own `mrbgem.rake`/
    `build_config.rb`). Its real body pushes the block's own RESULT when
    truthy (`x = blk.call(*x); ary.push x if x`), not the element the
    way `select`/`reject` do -- the new emitter case mirrors that
    exactly. 1 real call site: `Scene_Menu`'s own command-id remap
    (`mruby-rpg2k/mrblib/scene/menu.rb`, `ids.filter_map { |id|
    RPG2K3_COMMAND_IDS[id] } << RPG2K_COMMAND_KEYS.last`).

  Every real bytecode shape (`BLOCK R(a+1)` + `SENDB`/`SSENDB Ra
  :name n=0`, identical adjacency to every existing recognizer) was
  confirmed against real `mrbc -v -S` output on synthetic snippets
  before writing any recognizer, not assumed. No real receiver-class
  override of any of the three names exists anywhere in this closed
  world (confirmed: the only real `class Array`/`class Hash` reopens in
  `mruby-rpg2k`/`mruby-lcf`/`mruby-rgss`'s own `mrblib` are
  `array_include.rb`'s `#include?` and `array_sort.rb`'s
  `#sort`/`#sort!`, neither of which touches `each_index`, `each_key` or
  `filter_map`; no `class X < Array`/`< Hash` subclass exists at all).
  `each_line`/`each_char` (String) were investigated and deliberately
  left out of scope -- different receiver class, ~1 real call site each,
  not worth a separate `mrb_str_p`-gated emitter this round.

  Verified via a real whole-program regen diff: compiled entry points
  1965 -> 1967 (+2 fully-clean methods), coverage 85.1% -> 85.2%,
  `unhandled opcode BLOCK` 366 -> 361, `SENDB` 343 -> 338 (5 real
  `BLOCK`/`SENDB` call-site pairs newly inlined; most of the 15 real
  `each_index`/`each_key`/`filter_map` call sites found by source grep
  still hit the ordinary pre-existing gates this round didn't touch --
  an unresolved receiver type or another unsupported opcode inside the
  same block body -- same all-or-nothing contract every recognizer in
  this file already has). Independently verified with a real `g++
  -std=c++17 -fsyntax-only` compile of the actual `SKIP_UNSUPPORTED=1`
  generated output (with `#include <mruby/numeric.h>` inserted after the
  first line): the only errors remaining are the same six pre-existing,
  unrelated `int` -> `mrb_value` conversion errors in
  `anim_target`/`command_item` already documented on master -- zero new
  errors introduced. `scripts/rpg2k_logic_check.rb` (1201 checks),
  `scripts/rpg2k_scene_check.rb` (1062 checks) and
  `scripts/lcf_testbed_check.rb` all still pass.
