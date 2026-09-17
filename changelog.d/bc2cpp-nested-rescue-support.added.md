- `tools/bc2cpp/bc2cpp.rb` can now compile a method whose own real `rescue`
  construct sits entirely NESTED inside another one's own protected body --
  `RPG2k::Scene::Map#build_resolver`'s own `map_events = (@map.unit.events
  rescue nil)` modifier-rescue, sitting inside its own enclosing `rescue
  StandardError; ...; end`, and `RPG2k::Scene::Map#perform_teleport`'s own
  `RGSS::Profiler.section("map.transition.load") { @map = ... }` (itself
  already inside one rescue clause) with a second, unrelated nested rescue
  elsewhere in the same method -- previously an honest `#error unhandled
  opcode EXCEPT` regardless of how simple either rescue clause was on its
  own, since `recognize_rescue_regions`'s own "no nesting" guard rejected
  BOTH ends of any such pair outright, even though each individual shape
  was already correctly recognized as a standalone top-level construct.

  Confirmed via a fresh `mrbc -v` disassembly of a minimal reproduction of
  `build_resolver`'s own real shape that mrbc emits exactly two real catch
  handlers, one properly nested inside the other's own address range
  (`catch type: rescue begin: 0004 end: 0057 target: 0060` outer, `catch
  type: rescue begin: 0007 end: 0016 target: 0019` inner) -- a real, common
  composition this recognizer had no way to represent before. The "no
  nesting" guard now allows proper containment through (one handler's own
  `[begin_addr, end_addr]` fully inside another's), still rejecting a
  genuine partial overlap without containment (which real mrbc-generated
  code never produces anyway). New `top_level_rescue_regions` picks out,
  from any list of recognized regions, only those not themselves nested
  inside another region in that same list -- both `compile_method`'s own
  top-level rescue loop and `emit_proc_fallback_fn`'s own block/lambda-body
  rescue pass now claim only their own top-level regions this way, leaving
  anything nested inside one of them for that region's own separate,
  recursive extraction instead.

  `emit_rescue_try_body` gained that recursive nested-extraction pass,
  mirroring its own pre-existing nested-BLOCK_FALLBACK pass: a rescue
  region found strictly inside the one currently being extracted gets its
  own further-nested `mrb_protect_error`-based try-body function, textually
  prepended before the enclosing one (C++ forbids nested function
  definitions). Unlike a top-level region's ctx (sound as just `self` plus
  the method's own mandatory arguments, since a top-level region's
  `begin_addr` is always the very first real instruction after `ENTER`), a
  nested region's `begin_addr` is reached only after arbitrary earlier code
  in the enclosing try body has already run -- so rather than computing
  real liveness, its own ctx captures the entire register file by value
  (every `r1..r<nregs-1>` the enclosing function already declares, all
  plain `mrb_value` locals) via the exact same `extra_fields`/
  `extra_field_values` mechanism `BLOCK_FALLBACK_RESCUE_SUPPORT`'s own
  upvar pointers already use for "extra live state beyond self+args" --
  inherited unchanged from the enclosing call in addition to the saved
  registers, so a nested rescue inside a block body can still reach that
  block's own captured upvars exactly as freely as the block body itself
  can. The enclosing try-body's own nested-BLOCK_FALLBACK pass now also
  pre-claims every nested rescue region's own address range first (the
  same ordering `compile_method`'s top-level loop already uses relative to
  its own later BLOCK_SUPPORT/EACH_BLOCK_SUPPORT passes) so a block-
  carrying call inside a nested rescue's own body is claimed exactly once,
  by that nested region's own recursive pass -- caught live as a real
  `redefinition of ...` g++ error the first time this ran on
  `perform_teleport` before that ordering fix, not shipped that way.

  Verified against the real whole-program diagnostic: compiled entry
  points 2249 -> 2252, method-level coverage 97.0% -> 97.1%, `unhandled
  opcode EXCEPT` 9 -> 5 (both `build_resolver`'s own two-handler pair and
  `perform_teleport`'s own two-handler pair now compile fully clean; the
  remaining 5 -- `Game::Battle#deal_attack` (a real `ensure`, a genuinely
  different, non-`:rescue`-type catch handler this recognizer already
  correctly declines), `RPG2k#start`, `RPG2k::Scene::Map#
  try_open_debug_menu`, `RGSS.singleton#audio_probe`,
  `RGSS::Graphics.singleton#_transition_map` -- are different,
  not-yet-investigated shapes, not a regression), total `#error` markers
  124 -> 119. `scripts/rpg2k_logic_check.rb` (1201 checks),
  `scripts/rpg2k_scene_check.rb` (1062 checks), and
  `scripts/lcf_testbed_check.rb` all still pass unchanged. Directly
  inspected real generated output for both `build_resolver` (the nested
  try-body correctly reading `@map.unit.events` off its own captured `self`
  and returning it into the outer's own `r4`, feeding `EventResolver.new`)
  and `perform_teleport` (the block-carrying `RGSS::Profiler.section` call
  compiling exactly once, entirely inside the nested try-body, no
  duplicate definition). A real `g++ -std=c++17 -fsyntax-only` compile of
  the actual `SKIP_UNSUPPORTED=1` generated output confirms the exact same
  17 pre-existing, already-documented, unrelated errors as immediately
  before this change and zero new ones.
