- `tools/bc2cpp/bc2cpp.rb` can now compile a method declaring BOTH optional
  positional arguments AND keyword arguments in the same signature --
  `def deal_attack(b, target, swing_index = 0, charged: nil)`,
  `def initialize(allies, enemies, rng = nil, ..., rpg2003: false, party: nil,
  battle_type: 0)` (`Game::Battle`), `def build_animation(id, targets,
  battle = false, position: nil)` (`RPG2k::Scene::Map`) -- previously an
  honest `#error ... has non-mandatory arguments (optional/rest/keyword/
  block)` outright, since `OPTIONAL_ARG_SUPPORT` and `KEYWORD_ARG_SUPPORT`
  each required the other's own ENTER field to be zero.

  Confirmed via a fresh `mrbc -v` disassembly that the two compose
  mechanically, not just conceptually: `ENTER 2:8:0:0:3:0:0:0` (2 mandatory,
  8 optional, 3 keyword -- `Game::Battle#initialize`'s own real shape) still
  emits the exact same `opt+1`-JMP jump table `optional_arg_table` already
  recognizes, whose LAST target simply lands directly on the same
  `KEY_P`/`KARG`/`KEYEND` sequence `keyword_arg_table` already recognizes,
  wherever in the instruction stream that happens to sit -- the two
  recognizers never needed to interact, only their own independent gates
  (`kw.zero?` on the optional side, `opt.zero?` on the keyword side) needed
  to stop excluding each other's field.

  `optional_arg_table`/`keyword_arg_table` each dropped the other's
  zero-field requirement. `compile_method` gained a defensive combined
  check: if `opt.positive?` but its own jump-table shape didn't resolve, or
  ENTER's own real `kw` field is nonzero but `keyword_arg_table` couldn't
  recognize its own `KEY_P`/`KARG` shape, the WHOLE method is declined (both
  `opt_jmp_targets`/`kw_table` zeroed out) rather than silently compiling
  with half its own real arity ignored -- a method can never end up treated
  as "just optional" while quietly dropping real keyword parameters it
  actually declares, or vice versa. The entry wrapper's own `elsif kw_table`
  branch gained the same `mrb_nil_value()` default-initializer and `|`
  format-string marker (mrb_get_args' own boundary between mandatory and
  optional positions) `OPTIONAL_ARG_SUPPORT`'s own plain branch already
  established, plus the same `bc2cpp_given_opt`/`mrb_get_argc` extraction --
  `_impl`'s own signature and forward-declaration code needed no changes at
  all, since `arg_params`/`arg_c_types` already appended `bc2cpp_given_opt`
  (when `opt.positive?`) before any keyword parameters, in exactly this
  order, from `OPTIONAL_ARG_SUPPORT`'s own original construction.

  Verified against the real whole-program diagnostic: compiled entry points
  2245 -> 2247, method-level coverage 96.8% -> 96.9%, "has non-mandatory
  arguments" bucket 4 -> 1 (only `RGSS::ErrorReport::Tee#method_missing`'s
  own `*args, &block` shape remains -- a different, rest+block combination,
  out of scope this round), total `#error` markers 128 -> 126.
  `Game::Battle#deal_attack` -- one of the three previously-blocked-by-arity
  methods -- is NOT among the newly-clean ones despite compiling far enough
  to reach real body instructions now: its own `deal_attack_with_current_
  weapon` call sits inside a real `rescue` clause `recognize_rescue_regions`
  doesn't recognize, honestly surfacing as its own `#error unhandled opcode
  EXCEPT` instead (`EXCEPT` count 8 -> 9) -- a genuinely separate,
  pre-existing limitation this round doesn't touch, not a regression (this
  method was already fully unsupported before; it is simply blocked by a
  more specific, more accurate reason now). `Game::Battle#initialize` and
  `RPG2k::Scene::Map#build_animation` both compile fully clean, confirmed by
  direct inspection of their real generated bodies (the JMP-table switch,
  the keyword unpacking, and every downstream instruction all correct).
  `scripts/rpg2k_logic_check.rb` (1201 checks), `scripts/rpg2k_scene_check.rb`
  (1062 checks), and `scripts/lcf_testbed_check.rb` all still pass
  unchanged. A real `g++ -std=c++17 -fsyntax-only` compile of the actual
  `SKIP_UNSUPPORTED=1` generated output confirms the exact same 17
  pre-existing, already-documented, unrelated errors as immediately before
  this change and zero new ones.
