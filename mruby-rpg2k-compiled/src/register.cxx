// Swaps AOT-compiled C++ bodies in for 25 of Game::Picture's own 26 real
// methods (docs/adr/0139's own follow-up) -- everything but #initialize,
// which takes optional arguments bc2cpp's calling convention doesn't
// model, so it keeps running mruby-rpg2k's own interpreted mrblib body
// unchanged -- plus, as of docs/adr/0139 (the JMPNIL/LOADL opcode work),
// all 6 of Game::EnemyAction's own real bytecode-defined methods (its
// `attr_reader`-generated accessors are native, invisible to bc2cpp the
// same way every other attr_reader/attr_writer in this codebase is) --
// plus, as of docs/adr/0139's own array-literal-opcode follow-up (two
// classes compiled in the same round), 41 of Game::Screen's own 43 real
// bytecode-defined methods (39 as of that round; 2 more, #load_h/#pan,
// unblocked later by the GETIDX opcode a subsequent round added for
// Game::Actor -- see that class's own block below), INCLUDING
// #initialize itself this time (see that class's own registration block
// below for why it's different from the other three), and 32 of
// RPG2k::Window's own 35 real methods
// (mruby-rpg2k/mrblib/main.rb: the RPG2000-style UI window, skin/frame/
// cursor/contents/arrow rendering via four layered Sprites in a
// Viewport). Getting Screen's and Window's own methods clean needed four
// new opcode additions to bc2cpp itself: LOADSELF (`self.foo = ...`, an
// explicit-receiver self-send mrbc doesn't fold into SSEND), MUL
// (ADD/SUB's own fixnum-fastpath-else-mrb_funcall shape -- confirmed
// reading 3rd/mruby/src/vm.c: OP_ADD/OP_SUB/OP_MUL all expand from the
// identical OP_MATH macro), and ARRAY/AREF (a literal array and a
// destructuring multiple-assignment off one, both real, narrow, single-
// purpose mechanical translations of their own real OP_ARRAY/OP_AREF VM
// semantics -- see bc2cpp.rb's own comments on each). Landing MUL and
// AREF together unblocked three further Game::Screen methods
// (#restore_tint, #update_shake, #update_flash) neither opcode alone
// would have: #restore_tint destructures two Array-literal-shaped
// arguments (AREF), #update_shake/#update_flash each do a plain
// multiplication (MUL) -- real, additive value from doing this round's
// two classes together rather than in isolation. Two more classes joined in
// a third parallel round: 32 of Game::Transition's own 38 real methods
// (RPG2000's ~38 screen transition styles), the second target after
// Game::Screen whose own #initialize compiles clean and gets real ivar
// embedding; and Game::Actor, the biggest real target yet at 75 of its own
// methods, needing three more new opcodes (GETIDX/SETIDX, a computed-index
// Array/Hash read/write; GETGV, a bare global-variable read) that also
// unlocked 348 more real method bodies across roughly 30 other classes
// project-wide, confirming the same opcode-reuse payoff the prior round's
// MUL/AREF work already showed. A fourth round adds Game::Party (party-wide
// item/skill usability rules, equip/swap logic, skill damage formulas,
// state/status application, battle placement) -- 85 of its own 128 real
// bytecode-defined methods, needing six more new opcodes: NOP (a real,
// literal `do nothing` -- OP_NOP's own real VM semantics, emitted as a
// `while` loop's own condition-check jump target); ADDILV/SUBILV (a
// `while` loop's own `i += 1`/`i -= 1`-shaped local-variable increment/
// decrement, the exact same fixnum-fastpath-else-mrb_funcall shape ADDI/
// SUBI already have, just addressed differently); RANGE_INC/RANGE_EXC (an
// inclusive/exclusive Range literal, `mrb_range_new`); and RETURN_BLK (a
// `return` that isn't a method's own last statement -- looks block-
// specific by name, but is provably identical to a plain RETURN for every
// leaf method this compiler ever translates, see bc2cpp.rb's own comment
// for the real MRB_PROC_STRICT_P proof). This round's own full-sweep
// re-check (checking every already-shipped target against the final
// merged opcode set, not just this round's own new class -- the
// established discipline two rounds up this file's own history already
// learned the hard way) found one more: Game::Actor#set_exp, unblocked by
// SUBILV even though Game::Actor was never touched by this round's own
// source changes (see its own entry below). The same re-check also caught
// a real, live memory-safety bug already shipping in this exact file's
// own Game::Actor block, predating this round entirely: bc2cpp's own
// drop_unsafe_embeddings guard checked only arity shape
// (pure_mandatory_arity?), not whether #initialize's own body actually
// finishes compiling -- Game::Actor#initialize has pure mandatory arity
// (2 required args) but still ends in a real `.each` block (BLOCK/SENDB),
// so it was never going to compile either way, yet the old guard let 7
// real Fixnum ivars (@id/@exp/@level/@class_id/@faceset_index/
// @face_index/@battler_animation_override) through as "embeddable" -- 16
// real, already-registered Game::Actor methods below (faceset_index,
// set_faceset, weapon_crit_chance, ...) were generated with DATA_PTR(self)
// struct-field GETIV/SETIV codegen for an RData payload that was never
// actually allocated (no MRB_SET_INSTANCE_TT(actor, ...) call exists
// anywhere in this file, since nothing here ever suspected embedding was
// live for this class) -- real undefined behavior on every real
// Game::Actor instance, every time one of them ran. Fixed in bc2cpp.rb
// itself (drop_unsafe_embeddings now also requires compiles_clean?, the
// same real #error-marker check compile_send's own MONO-devirtualization
// fix already uses two follow-ups up in docs/adr/0139) -- confirmed
// directly against the regenerated output: Game::Actor no longer appears
// in bc2cpp's own "classes needing MRB_SET_INSTANCE_TT" diagnostic at
// all, and no DATA_PTR(self) access remains anywhere in its own compiled
// methods below; every one of Game::Actor's own 76 registered entry
// points is completely unaffected (identical arity/visibility/symbol),
// only the ivar access path underneath a handful of them changed from an
// unsafe struct-field dereference back to the ordinary, always-safe
// dynamic iv_tbl. A fifth, parallel round added RPG2k::Scene::MapViewer
// (34 of its own 42 real methods, the F9 debug-menu map overview/editor
// scene) alongside Game::Party, needing one more new opcode, GETIDX0
// (mrbc's own peephole for a literal `x[0]` index), which also unblocked
// 5 more methods project-wide (none in any already-shipped owner set). A
// sixth, parallel round adds Game::Battle (mruby-rpg2k/mrblib/game/
// battle.rb -- the headless turn-based/gauge combat-resolution engine:
// turn order, command resolution, hit/damage/state-infliction formulas,
// enemy AI action selection), 75 of its own 141 real bytecode-defined
// methods, and RPG2k::Scene::ItemMenu (mruby-rpg2k/mrblib/scene/
// item_menu.rb -- the field/battle item-use menu: item list scrolling/
// selection, target-selection including teleport-item map picking,
// applying item effects), 41 of its own 47. Neither needed any opcode
// work Game::Party/MapViewer's own round hadn't already added (Battle's
// gaps are all non-mandatory-#initialize-arity or a genuine Ruby block;
// ItemMenu's #initialize hits a real `super parent` call, SUPER, out of
// this compiler's scope, and its own #choose_item/#play_item_use_se
// needed RANGE_INC/RANGE_EXC, already landed the round before). Neither
// class's own #initialize compiles, so neither gets any ivar embedded. A
// seventh, parallel round adds two more RPG2k::Scene siblings, neither
// needing any new opcode work either: SkillMenu (mruby-rpg2k/mrblib/
// scene/skill_menu.rb -- the field/battle skill-use menu), 39 of its own
// 46 real methods, and DebugMenu (mruby-rpg2k/mrblib/scene/
// debug_menu.rb -- the F9 debug menu itself: Switch/Variable block-and-
// row editing plus the Map/Chipset/Animation tool pages), 33 of its own
// 39. SkillMenu's own #initialize has one non-mandatory optional
// argument, the same established gap as Picture/Window/Actor/Party/
// MapViewer above; DebugMenu's own #initialize is the first shipped
// target blocked by a real `super` call (OP_SUPER) instead -- a genuine
// class-hierarchy method-dispatch feature, not a narrow single-opcode
// translation, so out of scope the same way every other interpreted
// #initialize already is. Neither class's own #initialize compiles, so
// neither gets any ivar embedded. An eighth, parallel round adds two more
// RPG2k::Scene siblings, again neither needing any new opcode work:
// EquipMenu (mruby-rpg2k/mrblib/scene/equip_menu.rb -- the field equip
// screen: weapon/armor/accessory slot selection, a two-column bag-item
// candidate grid, per-stat before/after deltas), 29 of its own 36 real
// methods, and Menu (mruby-rpg2k/mrblib/scene/menu.rb -- the field main
// menu: the top-level party navigation hub covering Item/Skill/Equip/
// Status/Save/Quit, the party-status panel, the end-game confirmation
// dialog, and the gold display), 28 of its own 35. EquipMenu's own
// #initialize has one non-mandatory optional argument, the same
// established gap as Picture/Window/Actor/Party/MapViewer/SkillMenu
// above; Menu's own #initialize hits a real `super` call (SUPER), the
// same established gap as ItemMenu's/DebugMenu's own #initialize. One
// real near-miss was checked, not chased: Menu#draw_status_row's own
// `line = ->(n) { y + n * LINE_H }` hits a LAMBDA opcode never seen by an
// earlier round, but a lambda literal creates a real closure the same
// way BLOCK/SENDB do, just via different syntax -- the same permanently-
// out-of-scope closure-creation gap, not a narrow missing translation.
// Neither class's own #initialize compiles, so neither gets any ivar
// embedded. A ninth, parallel round adds Game::State (mruby-rpg2k/mrblib/
// game.rb, reopened by mruby-rpg2k/mrblib/game/lsd_io.rb) -- the whole-
// program root save/session object (party, switches, variables, map
// position, pictures, both timers, the message window config, screen-
// transition defaults, vehicle placement, and the Marshal/`.lsd`
// (de)serialisers), 23 of its own 32 real bytecode-defined methods, and
// RPG2k::Scene::StatusMenu (mruby-rpg2k/mrblib/scene/status_menu.rb --
// the field per-character status detail screen: stats, equipped gear,
// EXP progress for one selected party member, across five windows), 13
// of its own 21. Neither needed any new opcode work. Game::State's own
// #initialize (4 purely mandatory arguments) is the third target, after
// Game::Screen/Game::Transition above, whose own #initialize compiles --
// and by far the largest: 13 of its own ivars (all provably Fixnum) get
// real RData struct embedding, mixed safely on the same object with
// every other real (non-Fixnum) ivar staying on the ordinary dynamic
// iv_tbl. Confirmed safe against the exact Game::Actor-shaped bug two
// follow-ups up: `Game::State.load` (interpreted, a class method) never
// bypasses the compiled #initialize -- it constructs every real instance
// via a plain `new(party, map_id, x, y)` call, so mrb_data_init always
// runs before any embedded field is ever touched. StatusMenu's own
// #initialize hits a non-mandatory optional argument (plus a `super`
// call), the same established gap as every other non-embedding target
// above, so its own one real ivar stays unembedded too. A tenth, parallel
// round adds Game::MoveRoute (mruby-rpg2k/mrblib/game.rb -- the RPG2000
// "Set Move Route" event-command engine: a character's programmed queue
// of move/turn/wait/jump/effect sub-commands, with the repeat/skip-if-
// blocked flags a route carries), 18 of its own 19 real bytecode-defined
// methods, and RPG2k::Scene::ChipsetEditor (mruby-rpg2k/mrblib/scene/
// chipset_editor.rb -- the F9 debug menu's Chipset page: a Lower/Upper
// tile-passability grid editor), 17 of its own 20. Neither needed any new
// opcode work. MoveRoute's own #initialize hits the same non-mandatory-
// arguments gap as every other unembedded target above, this time via
// real keyword arguments; two more real methods, .from_page and
// .same_route?, are singleton (`def self.`) methods -- an existing,
// program-wide structural gap in bc2cpp's own build_registry (its own
// CLASS/MODULE/TDEF walk never recognizes an SCLASS-opened body), not new
// here, just the first class whose own singleton methods carry real logic
// worth naming. ChipsetEditor's own #initialize hits the same SUPER gap
// as ItemMenu's/DebugMenu's/Menu's own #initialize, this time paired with
// a `quit_on_close:` keyword argument too; its own #save_to_disk has a
// real `rescue StandardError` clause, and #draw_grid ends in a genuine
// Ruby block. This round's own full-sweep re-check (checking every
// already-shipped target against a real bc2cpp.rb bug fix, not just each
// round's own new classes -- the established discipline several rounds up
// this file's own history already learned the hard way) also caught and
// fixed a real, live correctness bug: extract_native_method_names (the
// whole-program native-method-name scanner) recognized MRB_SYM/MRB_OPSYM
// but not mruby core's own MRB_SYM_Q/MRB_SYM_B/MRB_SYM_E sibling macros
// ("name?"/"name!"/"name="), so ~75 real native predicate/bang/setter
// names (Array#empty?, Kernel#nil?/#frozen?, Numeric#zero?, Hash#key?,
// String#chomp!, ...) were invisible to the whole-program registry --
// surfaced concretely as Game::MoveRoute#empty? (`@commands.empty?`)
// getting wrongly reported MONO and devirtualized into calling itself,
// real infinite recursion, caught only because g++'s own
// -Winfinite-recursion happened to flag a literal self-call; the same
// collision against any other class's own same-named native method would
// have compiled clean and silently misresolved instead, invisible to any
// compiler warning. Fixed in bc2cpp.rb itself (see its own comment);
// confirmed by diff that every one of the fourteen previously-shipped
// classes' own generated C++ is byte-for-byte unchanged by the fix -- no
// live corruption existed in already-shipped code, this bug just hadn't
// been triggered by a same-named native/compiled collision yet. Neither
// MoveRoute's nor ChipsetEditor's own #initialize compiles, so neither
// gets any ivar embedded.
// mruby-rpg2k (this gem's own add_dependency) has already run its full gem
// init -- C hook *and* mrblib -- by the time this gem's own init runs
// (mrbgems.rake sequences gem_funcs[] in dependency order, each entry
// running its complete init before the next gem's own init starts), so
// all twenty-two classes are guaranteed to already exist below.
//
// An eleventh, parallel round adds RPG2k::Scene::Base (mruby-rpg2k/mrblib/
// scene/base.rb, reopened by mruby-rpg2k/mrblib/scene/battle_support.rb)
// -- the common superclass every other RPG2k::Scene::* class in this
// codebase inherits from. 17 of its own 29 real bytecode-defined methods
// compile clean, needing no new opcode work. #initialize (`def initialize
// parent`) compiles clean -- pure mandatory arity, and (being the root of
// the hierarchy) no `super` call to block it, unlike every subclass built
// on top of it. Its own 3 ivars (@parent, @db, @map_tree) are all opaque
// object references, never provably Fixnum, so it does not appear in
// bc2cpp's own "classes needing MRB_SET_INSTANCE_TT" diagnostic and stays
// a plain, non-embedding registration. Notably, since RPG2k::Scene::
// ItemMenu, RPG2k::Scene::DebugMenu and RPG2k::Scene::Menu's own
// #initialize are each blocked purely by their own `super parent` call
// into this now-clean-compiling #initialize (no other non-mandatory
// arguments), real SUPER opcode support could unlock all three in a
// future round -- out of scope here (whole-program coordination across
// every already-shipped scene class's own registration block), but
// flagged for later.
//
// The same round also adds Game::Character (mruby-rpg2k/mrblib/game.rb)
// -- the shared moving-on-map-entity state/movement protocol
// Game::Vehicle and the player/event drivers build on. 14 of its own 16
// real bytecode-defined methods compile clean, needing no new opcode
// work; #initialize (three optional arguments) and #front_tile (one)
// both stay interpreted via the same established non-mandatory-arity
// shape as every other non-embedding target above, so this class's own
// provably-typed ivars stay unembedded too, no MRB_SET_INSTANCE_TT call
// needed for it below.
//
// This same round also found and fixed a real, live bug in bc2cpp.rb's
// own IvarLayout.join -- the fixed-point per-ivar type-join the whole
// embedding analysis (and ArgTypes' own call-site argument-type
// inference, which reuses the identical join) is built on. A SETIV (or
// call-site argument) site whose own value traced to UNKNOWN used to have
// that contribution silently discarded whenever some *other*,
// earlier-processed site for the same ivar name had already joined in a
// concrete type -- keeping the old concrete type instead of poisoning to
// UNKNOWN the way a sound fixed-point join has to. Caught for real
// building Game::Character: #move_diagonal's own `@last_move_direction =
// [horizontal, vertical]` (a genuine Array literal, correctly traced to
// UNKNOWN) was getting silently dropped in favor of #initialize's own
// earlier `@last_move_direction = direction` (:fixnum) -- reported EMBED
// fixnum for an ivar that can, on a real code path, hold an Array. Not
// exploitable for Game::Character itself (its own #initialize never
// compiles at all, so the class-level gate above already refuses to embed
// anything regardless), but a live, already-shipped bug for classes whose
// own #initialize *does* compile: a fresh whole-program diagnostic taken
// before and after the fix shows Game::Screen losing 11 of its own
// previously-"embeddable" ivars (@frames, @shake_power/@shake_speed/
// @shake_frames/@shake_offset, @flash_frames, @pan_x/@pan_y/@pan_step,
// @fade_frames/@fade_transition) and Game::State losing one (@map_id) --
// both classes still keep several genuinely-sound embedded ivars each, so
// neither drops out of "classes needing MRB_SET_INSTANCE_TT" entirely,
// but the pre-fix set of embedded fields for both was real, live,
// over-permissive RData-struct layout. Every embedded-field SETIV this
// codegen emits already carries its own runtime `mrb_integer_p` guard
// (raising a real Ruby TypeError on a non-Integer write, never silently
// corrupting the struct) -- so this was never the Game::Actor-shaped
// undefined-behavior class of bug (an allocation that never happened);
// it was an over-permissive embedding decision that would have turned a
// legitimate non-Integer assignment (one the plain interpreter handles
// fine) into a crash the first time a real game session actually hit it.
// Since `rpg2k_compiled_gen.cpp` is regenerated by mrbgem.rake from
// bc2cpp.rb on every build (a real Rake prerequisite, not something this
// file has to duplicate), the very next build after this fix lands
// regenerates both classes' own generated code with the corrected
// (smaller, sound) embedded-field set automatically -- no hand-edit to
// either class's own registration block below was needed or made. See
// docs/adr/0139's own Game::Character follow-up for the full writeup.
//
// A twelfth, independent round adds RPG2k::Scene::SaveLoad (mruby-rpg2k/
// mrblib/scene/save_load.rb) -- the file-select screen shared by
// Scene::Menu's own Save command and Scene::Title's Continue entry. 12 of
// its own 22 real bytecode-defined methods compile clean, needing no new
// opcode work at all. #initialize (`initialize parent, state, mode`) does
// NOT compile -- it opens with its own `super parent` call into
// RPG2k::Scene::Base (SUPER, matching ItemMenu's/DebugMenu's/Menu's/
// ChipsetEditor's own gap -- a fourth class this same SUPER-opcode lead
// would unlock) and also builds @slots via a real `(1..SLOT_COUNT).map {
// |slot| ... }` block (BLOCK/SENDB). Since #initialize never compiles,
// its own provably-typed ivars (@mode, Symbol; @arrow_anim, Fixnum) stay
// unembedded too, confirmed directly against the real generated output:
// RPG2k::Scene::SaveLoad does not appear in bc2cpp's own "classes needing
// MRB_SET_INSTANCE_TT" diagnostic. #dispose/#update each have their own
// `&:symbol`-block-pass call (SENDB); #draw_arrow_fallback,
// #initial_index, #build_slot_windows, #refresh_slot_windows, and
// #draw_slot_faces each end in a genuine Ruby block (BLOCK/SENDB); and
// #load_face_bitmap/#slot_timestamp each have a real `rescue` clause
// (RESCUE/RAISEIF/EXCEPT), the same established gap as ItemMenu's own
// #load_face_bitmap/ChipsetEditor's own #save_to_disk. Every method but
// #initialize/#dispose/#update sits after a bare `private` in the real
// source, so all 12 registered entries below use
// mrb_define_private_method.
//
// A thirteenth, parallel round adds RPG2k::Scene::Order (mruby-rpg2k/
// mrblib/scene/order.rb) -- the field Order screen (RPG2003 main menu ->
// Order): a pick-and-place party reorder UI across a left (remaining) /
// right (picked) column pair, plus a Confirm/Redo prompt once every
// member has been picked. 12 of its own 16 real bytecode-defined methods
// compile clean, needing no new opcode work at all. #initialize (`super
// parent` as its own first statement) matches DebugMenu's/Menu's/
// ChipsetEditor's/SaveLoad's own SUPER gap exactly -- a fifth class this
// same SUPER-opcode lead would unlock. The other 3 gaps are all a genuine
// Ruby block (BLOCK/SENDB): #build_windows and #refresh_left_window/
// #refresh_right_window each use a real `each_with_index do |...| ... end`.
// #initialize never compiles, so drop_unsafe_embeddings correctly refuses
// to embed any of this class's own provably-typed ivars (@counter/
// @cursor_index/@confirm_index, all Fixnum; @focus, Symbol) -- confirmed
// directly against the real generated output: RPG2k::Scene::Order does
// not appear in bc2cpp's own "classes needing MRB_SET_INSTANCE_TT"
// diagnostic. 2 public methods (#update/#dispose) are registered first,
// then a single bare `private` (in effect through the end of the class
// body) makes the other 10 registered below private too.
//
// The same round's own adversarial bug hunt across every already-shipped
// class (not new-class coverage) found a second real, live bug in
// bc2cpp.rb's own compile_send: a bare `/n=(\d+)/` regex parsing a SEND/
// SSEND call site's own disassembled argument count only recognized a
// plain positional-argument shape ("n=3"), silently misparsing two other
// real shapes mrbc's own disassembler emits instead of rejecting them --
// a keyword-argument call site ("n=3|nk=1") had its whole keyword-Hash
// argument silently dropped, and a splat call site ("n=*") fell through
// `nil.to_i` to a silently-wrong zero-argument call. Confirmed live, not
// hypothetical, against six already-shipped, already-compiled methods:
// `Game::Battle#enemy_basic_action`/`#enemy_fallback_attack`'s own
// `deal_attack(..., charged: charged)` silently dropped `charged:`, so
// every charged enemy attack routed through either method called
// #deal_attack with its own `charged: nil` default instead of the
// caller's real charged state; `Game::Actor#knock_out!`/`Game::Battle
// #inflict_state`'s own `Game::States.prune(ids, table, keep:
// permanent_states)` silently dropped `keep:`, so a real
// permanently-protected state (e.g. an innate racial trait modeled as a
// state) could be pruned away as if no exemption list existed at all;
// `Game::Actor#restore_class`'s own `set_level(@level, preserve_mod:
// false)` silently called with `preserve_mod: true` instead (a real,
// load-bearing inversion -- the source's own adjacent comment explains
// why `false` is deliberate here); and `RPG2k::Scene::DebugMenu
// #play_animation`'s own call into three real MANDATORY keyword
// arguments (`RPG2k::Scene::Map#anim_target(tx, ty, height:, index:,
// flash_target:)`, no defaults at all) used to silently compile a call
// that would raise a real ArgumentError at runtime the moment it ran, not
// just pass a wrong value. Unlike the same round's IvarLayout.join fix
// (a wrong embedding decision caught by a runtime type guard before it
// could corrupt anything), this bug produced genuinely wrong *behavior*
// with no safety net at all -- the generated C++ compiled and linked
// clean either way, so nothing short of noticing the real gameplay
// symptom would ever have caught it. Fixed at the root in bc2cpp.rb:
// compile_send now recognizes both the keyword and splat disassembly
// shapes and refuses to compile either (the established #error-marker
// fallback every other unmodeled shape here already gets) instead of
// silently mistranslating them. All six affected methods above are no
// longer registered below -- see each one's own removal comment at its
// former call site for the per-method writeup -- and now correctly stay
// on the interpreter. See docs/adr/0139's own follow-up for the full
// writeup, including the real build/nm -C verification that each
// affected class's own entry-point count dropped by exactly the number
// of methods this fix stopped compiling.
//
// A fourteenth, independent round adds Game::Shop (mruby-rpg2k/mrblib/
// game.rb) -- the RPG2000 buy/sell shop-menu backing model: the stocked
// good list, buy/sell affordability and the 99-item stack cap, half-price
// selling. 11 of its own 14 real bytecode-defined methods compile clean,
// needing no new opcode work at all: #price/#name/#description/#equip?
// each read one database row (AREF-shaped) and #equip? also builds and
// tests a Range literal (RANGE_INC) plus ordinary POLY dispatch on
// #cover? (never devirtualized: #cover? collides with mruby core's own
// native Range#cover?); #sellable_items chains three ordinary POLY
// sends; #max_buy/#max_sell/#sell_price/#sellable? are plain arithmetic/
// conditional compositions of the above, #sell_price and #max_sell each
// devirtualizing straight into #price's/#sellable?'s own _impl (MONO).
// The 3 gaps are the same two already-established out-of-scope shapes:
// #initialize (a genuine Ruby block, BLOCK/SENDB) and #buy/#sell (each
// with one non-mandatory optional argument). Since #initialize never
// compiles, drop_unsafe_embeddings correctly refuses to embed any of
// this class's own ivars -- confirmed directly against the real
// generated output: Game::Shop does not appear in bc2cpp's own "classes
// needing MRB_SET_INSTANCE_TT" diagnostic.
//
// A real, concrete instance of the exact native-name-collision shape
// extract_native_method_names' own MRB_SYM_Q/B/E-macro coverage protects
// against: `:name` reports POLY (2 defs: Game::Shop, <native>) in this
// class's own whole-program registry dump with NATIVE_SRCS set the same
// way mrbgem.rake always does (Game::Shop#name collides by bare name
// with mruby core's own Symbol#name/Class#name, registered via
// src/symbol.c's own ROM method table) -- confirmed for real here, not
// just by analogy, so #name correctly stays ordinary mrb_funcall dispatch
// below, never a direct call into Game__Shop_name_impl from any other
// compiled call site in the whole program.
//
// A fifteenth, independent round adds Game::Map (mruby-rpg2k/mrblib/
// game.rb, reopened by mruby-rpg2k/mrblib/game/battle_support.rb) -- one
// loaded map's own tile-layer data (dimensions/chipset id, the lower/upper
// tile-id layer arrays, and Tile Substitution's own per-layer rewrite
// table). 12 of its own 13 real bytecode-defined methods compile clean,
// needing no new opcode work at all. #substitute_tile is the one gap
// (confirmed against its own real generated #error line): it ends in two
// real `.each { |k, v| ... }` blocks (BLOCK/SENDB), the same established
// out-of-scope shape every other block-using method above already
// documents. #initialize (`initialize id, unit`) compiles clean -- pure
// mandatory arity, no super, no block -- and is the fourth target whose
// own ivars actually get real RData embedding, after Game::Screen/
// Game::Transition/Game::State above: @id and @revision are both real,
// provably-Fixnum fields on a new Game__Map_ivars struct.
//
// Checked directly against the exact Game::Actor-shaped embedding bug
// several follow-ups up, not assumed safe by analogy: this class's own
// single real construction site (`Game::Map.new id, LCF::MapUnit.new
// (...)`, mruby-rpg2k/mrblib/main.rb's own #load_map) always goes through
// the compiled #initialize -- confirmed by grepping the whole closed world
// for `Game::Map.new`/`.allocate`/a subclass and finding exactly that one
// plain `.new` call site, no bypass, and no subclass anywhere. The other 7
// real ivars (@width/@height/@chipset_id -- each `unit.<method>`, a method
// call's own return value, never traced by this compiler's Fixnum-literal-
// only inference; @lower/@upper/@substitutions -- Array/Hash literals; the
// two @substitution_snapshot_* cache fields, also opaque) all stay UNKNOWN
// and so stay on the ordinary dynamic iv_tbl, mixed safely on the same
// object with the two embedded fields, the same mixed-embedding shape
// Game::Screen/Game::Transition/Game::State already established.
//
// #set_tile/#tile are `private` (a bare `private` mid-class-body in
// game.rb's own reopening, in effect through the end of it); #initialize
// is forced private by mruby's own interpreter (mrb_define_method_raw's
// own special case for the name, not a source-level `private` call, same
// as every other compiled #initialize in this file); every other method
// -- including #sync_layers_to_unit, defined in the *separate* `class Map`
// reopening in battle_support.rb, which starts its own fresh, default-
// public visibility scope -- is public.
//
// A sixteenth, independent round adds Game::EnemyAi (mruby-rpg2k/mrblib/
// game/battle_support.rb) -- the outside-world collaborator Game::Battle's
// own enemy action-pattern logic reads through (skill-table/database
// lookups, casting-eligibility/effectiveness formulas reused from
// Game::Party, switch read/write, and the party's own average level),
// never a database or game-state owner itself. 9 of its own 10 real
// bytecode-defined methods compile clean, needing no new opcode work at
// all, including #initialize itself (2 purely mandatory arguments, `db,
// state`, no super, no block). The one gap, #party_level, ends in a real
// `actors.each { |a| ... }` block (BLOCK/SENDB), the same established
// out-of-scope shape every other block-using method in this file already
// documents -- confirmed directly against the real whole-program
// diagnostic (SKIP_UNSUPPORTED=1 silently drops it, no generated entry
// point at all), not assumed from an earlier round's own less careful
// count.
//
// Unlike every other #initialize-compiling target above, though, neither
// of this class's own two ivars (@db, @state) ever gets embedded: both
// are opaque object references (a database table and a Game::State
// instance respectively), never provably Fixnum/Symbol -- #initialize's
// own real `# bc2cpp: (, Game::State)` class annotation (added several
// follow-ups up, already present in the real source before this round)
// confirms @state's real class for devirtualization purposes only;
// ClassLayout/ClassAnnotations deliberately never feed IvarLayout's own
// struct-field lattice, which models only Fixnum/Symbol primitives.
// Confirmed directly against the real generated output: Game::EnemyAi
// does not appear in bc2cpp's own "classes needing MRB_SET_INSTANCE_TT"
// diagnostic, so no MRB_SET_INSTANCE_TT call belongs in its own
// registration block below.
//
// Every real construction site in the whole closed world goes through a
// plain `Game::EnemyAi.new(db, state)` call -- mruby-rpg2k/mrblib/scene/
// battle.rb's own Scene::Battle#initialize, plus 7 in scripts/
// rpg2k_logic_check.rb's own CRuby test harness -- confirmed by grepping
// the whole closed world for `Game::EnemyAi.new`/`.allocate`/a subclass
// and finding no bypass and no subclass anywhere. Moot for memory safety
// here specifically, since nothing ends up embedded either way, but
// checked anyway, the same construction-site discipline every other
// embedding-candidate target above follows.
//
// No bare `private` anywhere in the class body (it opens its own fresh
// scope inside game/battle_support.rb, the same file Game::EnemyAction/
// Game::Troop/Game::States each independently reopen with their own
// visibility state), so every method below is `mrb_define_method` except
// #initialize itself, forced private by mruby's own interpreter
// regardless of source, the same always-private special case as every
// other compiled #initialize in this file.
//
// A seventeenth, independent round adds Game::ChipSet (mruby-rpg2k/mrblib/
// game.rb) -- one loaded chipset's own tile graphic name plus the lower/
// upper passability tables, terrain table, and water-animation parameters.
// ALL 9 of its own real bytecode-defined instance methods compile clean,
// needing no new opcode work at all; see compiled_gems.rb's own comment on
// this gem's `owners:` entry for the full writeup, including the real
// bitwise/modulo-operator SEND-name-extraction bug this class's own
// #passable_tile?/#landable_tile? surfaced in bc2cpp.rb itself -- also live
// in RPG2k::Scene::ChipsetEditor#toggled_byte/#cell_color_for and 30 other
// already-shipped methods across a dozen classes, fixed at the root, every
// affected class's own generated output regenerating correctly with the
// fix in place. #initialize (`initialize db, id`) compiles clean -- pure
// mandatory arity, the fifth target after Game::Screen/Game::Transition/
// Game::State/Game::Map above whose own ivars get real RData struct
// embedding: @animation_type/@animation_speed, mixed safely with this
// class's own String/Array-typed (UNKNOWN) ivars on the ordinary dynamic
// iv_tbl.
//
// An eighteenth, independent round adds Game::Timer (mruby-rpg2k/mrblib/
// game.rb) -- the RPG2000 Timer/Timer2 countdown backing model (both are
// real instances of this one class, held as Game::State's own @timers
// array; there is no separate "Timer2" class anywhere in the closed
// world, confirmed by grep). 7 of its own 10 real bytecode-defined
// methods compile clean, needing no new opcode work at all -- this class
// is exactly the shape the operator-regex bug above was found in:
// #display_text's own `s % 60` compiles to a real Integer#% send,
// confirmed directly against the real generated output
// (`mrb_funcall(M, r4, "%", 1, r5)`, never the pre-fix empty-string-name
// shape). #set (`seconds * FPS + (FPS - 1)`) exercises MUL/ADDI plus the
// nested-lexical-scope GETCONST fix to resolve the bare `FPS` constant
// via Game::Timer -> Game -> Object. #start (`visible, in_battle =
// false`), #tick (`battle = false`) and #drawn? (`battle = false`) each
// have one non-mandatory optional argument -- the same established
// out-of-scope shape every other unembedded target above already
// documents.
//
// #initialize compiles clean (zero arguments, pure mandatory arity), but
// the whole-program EMBED diagnostic proposes nothing for this class at
// all -- confirmed directly, not assumed: @running/@visible/@in_battle
// are booleans (a type this compiler's embedding lattice doesn't model),
// and @frames -- despite a literal-Fixnum source in #initialize (`0`)
// and #set (`seconds * FPS + ...`) -- gets poisoned back to UNKNOWN by
// #load_h's own `h[:frames] || 0` (a real opaque Hash#[] read on a
// caller-provided Hash), the same IvarLayout.join fixed-point poisoning
// behaviour the earlier round's own join() bugfix established. So
// Game::Timer does not appear in bc2cpp's own "classes needing
// MRB_SET_INSTANCE_TT" diagnostic. Confirmed moot regardless by the
// real, single construction site for this class in the whole closed
// world (`Game::State#initialize`'s own `@timers = [Timer.new,
// Timer.new]`, mruby-rpg2k/mrblib/game.rb -- no subclass, no
// `.allocate`, no bypass, grepped directly).
//
// Real full-sweep synergy from adding this class: :seconds and
// :display_text are both MONO (Game::Timer is their one and only real
// bytecode definition anywhere), so already-shipped Game::State's own
// #timer_seconds/#timer2_seconds/#timer_display_text now devirtualize
// their own internal `timer(id).seconds`/`.display_text` call straight
// into Game__Timer_seconds_impl/Game__Timer_display_text_impl instead of
// ordinary mrb_funcall, confirmed directly against the real regenerated
// output.
//
// A twenty-first, independent round adds RPG2k::Scene::MapWorld
// (mruby-rpg2k/mrblib/scene/base.rb) -- the small adapter Scene::Map's own
// #initialize builds (`@world = MapWorld.new(self, @rng)`) to bridge
// Game::MoveRoute/Game::MoveType's own small `world` protocol
// (passability, hero position, switch/sound side effects, randomness) onto
// the owning scene and its Game::State, without either movement-engine
// class needing a direct Scene::Map reference. 7 of its own 8 real
// bytecode-defined methods compile clean, needing no new opcode work at
// all: #initialize, #passable?, #can_land?, #hero_position (an Array
// literal off two chained sends, ARRAY-opcode-shaped), #in_sight?,
// #set_switch (SETIDX's own real `mrb_funcall(..., "[]=", ...)` fallback,
// since the real receiver -- Game::Switches -- is never a raw Array/Hash),
// and #random. The one gap, #play_sound, has a real `rescue StandardError`
// clause -- the same established out-of-scope shape every other
// rescue-using method in this file already documents; confirmed directly
// against the real whole-program diagnostic (SKIP_UNSUPPORTED=1 lists it
// under "skipped (unsupported, left on the interpreter)", no generated
// entry point at all). It already carries a real `# bc2cpp: (String, , ,
// )` magic-comment annotation in the source (predating this round), which
// resolves to no actual type claim (`ANNOTATED ... ([nil, nil, nil, nil]
// -> nil)`) since this compiler's annotation parser only recognizes
// fixnum/symbol tokens, never String -- moot either way, since the rescue
// clause alone keeps this method interpreted regardless of any annotation.
//
// #initialize (`initialize scene, rng`) compiles clean -- pure mandatory
// arity, no super, no block -- but neither of this class's own two ivars
// (@scene, @rng) ever gets embedded: both are opaque object references (a
// RPG2k::Scene::Map and a Game::Rng instance respectively), never provably
// Fixnum/Symbol. Confirmed directly against the real generated output:
// RPG2k::Scene::MapWorld does not appear in bc2cpp's own "classes needing
// MRB_SET_INSTANCE_TT" diagnostic, so no MRB_SET_INSTANCE_TT call belongs
// in its own registration block below. Every real construction site in
// the whole closed world goes through a plain `MapWorld.new(scene, rng)`
// call -- mruby-rpg2k/mrblib/scene/map.rb's own real `@world =
// MapWorld.new(self, @rng)` (inside a `RGSS::Profiler.section` block, not
// #initialize itself, but still a real, unconditional construction site),
// plus one in this project's own scripts/rpg2k_scene_check.rb CRuby test
// harness (`RPG2k::Scene::MapWorld.new(nil, nil)`, exercising #play_sound
// only) -- confirmed by grepping the whole closed world for
// `MapWorld.new`/`.allocate`/a subclass and finding no bypass and no
// subclass anywhere.
//
// Every one of #passable?/#can_land?/#hero_position/#play_sound/#random/
// #set_switch is a genuinely POLY name in the whole-program registry --
// RPG2k::Scene::VehicleWorld (the same file, right below MapWorld, "the
// same `world` protocol... for a Move Event/Set Move Route driving a
// vehicle") defines every one of them too, plus #passable? also collides
// with Game::ChipSet, #random with Game::Rng, and #set_switch with
// Game::Interpreter/Game::EnemyAi. None of that blocks registering
// MapWorld's own methods below -- POLY only affects whether some *other*
// compiled call site devirtualizes into one of these, never whether a
// class's own methods can be registered. No bare `private`/`protected`
// anywhere in the class body, so every method below is
// `mrb_define_method` except #initialize itself, forced private by
// mruby's own interpreter regardless of source, the same always-private
// special case as every other compiled #initialize in this file. A real
// lead for a future round: RPG2k::Scene::VehicleWorld's own identical
// protocol shape.
//
// Game::Picture's own #initialize can't be compiled (optional arguments
// via an `opts = {}` keyword-style hash), so even before any ivar is
// looked at, bc2cpp's own drop_unsafe_embeddings guard already refuses to
// emit embedded-struct GETIV/SETIV for it -- that would need the struct
// allocated in #initialize (mrb_data_init) -- so every ivar access below
// still goes through the ordinary dynamic iv_tbl, no MRB_SET_INSTANCE_TT
// call needed here, unlike Game::Screen's own block below. (An earlier
// version of this comment additionally claimed 11 of Picture's own ivars
// -- @x, @y, @show_x, @show_y, @zoom, @opacity, @red, @green, @blue,
// @saturation, @frames -- were themselves individually "provably Fixnum";
// that was never verified against the real per-ivar EMBED diagnostic and
// this class's own gate makes it moot either way -- see the real fix
// above.) RPG2k::Window is the same shape: its own #initialize can't
// compile either (four optional arguments), so drop_unsafe_embeddings
// refuses to embed anything here too -- confirmed directly against the
// real generated output: RPG2k::Window does not appear in bc2cpp's own
// "classes needing MRB_SET_INSTANCE_TT(..., MRB_TT_DATA)" diagnostic, and
// no DATA_PTR(self) access appears anywhere in its own compiled methods
// below.
#include <mruby.h>
#include <mruby/class.h>

// Generated at build time by tools/bc2cpp/bc2cpp.rb from mruby-rpg2k's own
// real mrblib/game.rb (mrbgem.rake's own `file` rule runs it before this
// translation unit is compiled).
#include "rpg2k_compiled_gen.cpp"

extern "C" void mrb_mruby_rpg2k_compiled_gem_init(mrb_state* M) {
  RClass* game = mrb_module_get(M, "Game");
  RClass* picture = mrb_class_get_under(M, game, "Picture");

  mrb_define_method(M, picture, "opacity", Game__Picture_opacity,
                    MRB_ARGS_NONE());
  mrb_define_method(M, picture, "x", Game__Picture_x, MRB_ARGS_NONE());
  mrb_define_method(M, picture, "y", Game__Picture_y, MRB_ARGS_NONE());
  mrb_define_method(M, picture, "to_h", Game__Picture_to_h, MRB_ARGS_NONE());
  // #step and #finish_move are both `private` in the real interpreted
  // source (mruby-rpg2k/mrblib/game.rb -- a bare `private` right before
  // their own def, still in effect through the end of the class body).
  // bc2cpp's own visibility tracking flags this in its own diagnostic
  // output; mrb_define_method here would silently make a private method
  // externally callable -- a real, observable behavior change (confirmed
  // the hard way: found via a runtime diff against the pure interpreter,
  // which raises NoMethodError on `picture.step(...)` from outside the
  // class -- our own compiled build didn't, before this fix).
  mrb_define_private_method(M, picture, "step", Game__Picture_step,
                            MRB_ARGS_REQ(2));
  mrb_define_method(M, picture, "update", Game__Picture_update,
                    MRB_ARGS_NONE());
  mrb_define_method(M, picture, "zoom", Game__Picture_zoom, MRB_ARGS_NONE());
  mrb_define_method(M, picture, "red", Game__Picture_red, MRB_ARGS_NONE());
  mrb_define_method(M, picture, "green", Game__Picture_green, MRB_ARGS_NONE());
  mrb_define_method(M, picture, "blue", Game__Picture_blue, MRB_ARGS_NONE());
  mrb_define_method(M, picture, "finish_x", Game__Picture_finish_x,
                    MRB_ARGS_NONE());
  mrb_define_method(M, picture, "finish_y", Game__Picture_finish_y,
                    MRB_ARGS_NONE());
  mrb_define_method(M, picture, "finish_zoom", Game__Picture_finish_zoom,
                    MRB_ARGS_NONE());
  mrb_define_method(M, picture, "finish_opacity", Game__Picture_finish_opacity,
                    MRB_ARGS_NONE());
  mrb_define_method(M, picture, "finish_red", Game__Picture_finish_red,
                    MRB_ARGS_NONE());
  mrb_define_method(M, picture, "finish_green", Game__Picture_finish_green,
                    MRB_ARGS_NONE());
  mrb_define_method(M, picture, "finish_blue", Game__Picture_finish_blue,
                    MRB_ARGS_NONE());
  mrb_define_method(M, picture, "finish_saturation",
                    Game__Picture_finish_saturation, MRB_ARGS_NONE());
  mrb_define_method(M, picture, "frames_left", Game__Picture_frames_left,
                    MRB_ARGS_NONE());
  mrb_define_method(M, picture, "saturation", Game__Picture_saturation,
                    MRB_ARGS_NONE());
  mrb_define_method(M, picture, "shown?", Game__Picture_shown_,
                    MRB_ARGS_NONE());
  mrb_define_method(M, picture, "move_to", Game__Picture_move_to,
                    MRB_ARGS_REQ(9));
  mrb_define_method(M, picture, "moving?", Game__Picture_moving_,
                    MRB_ARGS_NONE());
  mrb_define_method(M, picture, "erase!", Game__Picture_erase_,
                    MRB_ARGS_NONE());
  mrb_define_private_method(M, picture, "finish_move",
                            Game__Picture_finish_move, MRB_ARGS_NONE());

  // Game::EnemyAction (docs/adr/0139): all 6 of its real bytecode-defined
  // methods compile clean -- `int_of`/`bool_of` are `private` in the real
  // interpreted source (a bare `private` right before their own def, see
  // mruby-rpg2k/mrblib/game/battle_support.rb), flagged by bc2cpp's own
  // == compiled entry points == diagnostic exactly like Game::Picture's
  // #step/#finish_move above -- mrb_define_private_method for both, or a
  // real, observable behavior change (a private method silently made
  // externally callable) would ship unnoticed the same way that one did.
  // #initialize itself is *also* always private -- not from any `private`
  // call in the source, but a real interpreter special case (mruby's own
  // src/class.c forces #initialize/#initialize_copy/#respond_to_missing?
  // private unconditionally at `def`-time); bc2cpp.rb's build_registry now
  // models this rule directly (docs/adr/0139) and flags it the same way.
  RClass* enemy_action = mrb_class_get_under(M, game, "EnemyAction");
  mrb_define_private_method(M, enemy_action, "initialize",
                            Game__EnemyAction_initialize, MRB_ARGS_REQ(1));
  mrb_define_method(M, enemy_action, "skill?", Game__EnemyAction_skill_,
                    MRB_ARGS_NONE());
  mrb_define_method(M, enemy_action, "transform?", Game__EnemyAction_transform_,
                    MRB_ARGS_NONE());
  mrb_define_method(M, enemy_action, "basic?", Game__EnemyAction_basic_,
                    MRB_ARGS_NONE());
  mrb_define_private_method(M, enemy_action, "int_of", Game__EnemyAction_int_of,
                            MRB_ARGS_REQ(3));
  mrb_define_private_method(M, enemy_action, "bool_of",
                            Game__EnemyAction_bool_of, MRB_ARGS_REQ(2));

  // Game::Screen (docs/adr/0139's own array-literal-opcode follow-up): 39 of
  // its 43 real bytecode-defined methods compile clean. Unlike Game::Picture/
  // Game::EnemyAction above, #initialize itself is one of them -- it takes
  // zero arguments (`def initialize; @r = @g = ... ; end`, no opts hash, no
  // opcode this compiler doesn't model), so bc2cpp's own
  // drop_unsafe_embeddings guard does NOT refuse to embed here: 21 of
  // Screen's own ivars (@frames, @shake_power/@shake_speed/@shake_frames/
  // @shake_offset, @flash_r/@flash_g/@flash_b/@flash_power/@flash_strength/
  // @flash_frames/@flash_total, @pan_x/@pan_y/@pan_tx/@pan_ty/@pan_step,
  // @fade/@fade_target/@fade_frames/@fade_transition -- all provably
  // Fixnum) are real struct fields on a `Game__Screen_ivars*` RData
  // payload, per the whole-program `EMBED` diagnostic. That means
  // #initialize's own compiled body calls mrb_data_init on `self` --
  // which mruby's own mrb_data_init (mruby/data.h) asserts is already
  // MRB_TT_DATA (`mrb_assert(mrb_data_p(v))`) -- so the class itself has
  // to be tagged MRB_TT_DATA *before* any Game::Screen.new can ever run,
  // exactly the same real requirement mruby-rgss/src/lib.cxx's own natively
  // -implemented classes (Sprite, Rect, Viewport, ...) already meet via
  // their own MRB_SET_INSTANCE_TT calls -- the first time a *-compiled gem
  // needs this (neither mruby-lcf-compiled's nor this gem's own
  // Picture/EnemyAction blocks above ever embed anything, so neither one
  // has ever needed it before).
  //
  // The other 14 real ivars (@r/@g/@b/@sat/@tr/@tg/@tb/@tsat -- their own
  // source is Game.clamp's return value or the NEUTRAL constant, neither
  // traced by bc2cpp's Fixnum-literal-only type inference;
  // @shake_continuous/@flash_continuous/@pan_locked -- booleans, a type
  // this compiler's embedding lattice doesn't model at all; @transition --
  // a real Game::Transition object reference, never primitive) stay on the
  // ordinary dynamic iv_tbl, read/written through the interpreter's own
  // mrb_iv_get/mrb_iv_set exactly as before -- safe to mix with the 21
  // embedded fields on the very same object: every compiled method's own
  // GETIV/SETIV already knows, per ivar, whether it's an embedded struct
  // field or an ordinary iv_tbl entry (bc2cpp's ivar_layout keyed lookup),
  // so nothing here has to track which is which by hand.
  //
  // Only 2 real methods stay interpreted now: #erase/#show both take an
  // optional `frames = nil` argument, the same non-mandatory-arity gap
  // that already keeps Game::Picture#initialize/RPG2k::Window#initialize
  // interpreted. #load_h (`h[:pan_x]`, a Hash#[] read) and #pan
  // (`PAN_DELTA[direction]`, same shape) were blocked by the same real
  // GETIDX gap until docs/adr/0139's own Game::Actor follow-up added it --
  // a whole-program opcode addition made for a different class entirely
  // reaching back and unblocking two more methods here, the same real
  // synergy the ARRAY/AREF round already showed for #restore_tint/
  // #update_shake/#update_flash above.
  RClass* screen = mrb_class_get_under(M, game, "Screen");
  MRB_SET_INSTANCE_TT(screen, MRB_TT_DATA);

  // #initialize is always private (the same real interpreter special case
  // as Game::EnemyAction#initialize above -- mruby's own src/class.c forces
  // it regardless of source, not a bare `private` call here).
  mrb_define_private_method(M, screen, "initialize", Game__Screen_initialize,
                            MRB_ARGS_NONE());
  mrb_define_method(M, screen, "to_h", Game__Screen_to_h, MRB_ARGS_NONE());
  mrb_define_method(M, screen, "load_h", Game__Screen_load_h, MRB_ARGS_REQ(1));
  mrb_define_method(M, screen, "tint", Game__Screen_tint, MRB_ARGS_NONE());
  mrb_define_method(M, screen, "tinting?", Game__Screen_tinting_,
                    MRB_ARGS_NONE());
  mrb_define_method(M, screen, "shake_offset", Game__Screen_shake_offset,
                    MRB_ARGS_NONE());
  mrb_define_method(M, screen, "shaking?", Game__Screen_shaking_,
                    MRB_ARGS_NONE());
  mrb_define_method(M, screen, "flash_color", Game__Screen_flash_color,
                    MRB_ARGS_NONE());
  mrb_define_method(M, screen, "flashing?", Game__Screen_flashing_,
                    MRB_ARGS_NONE());
  mrb_define_method(M, screen, "pan_offset", Game__Screen_pan_offset,
                    MRB_ARGS_NONE());
  mrb_define_method(M, screen, "pan_locked?", Game__Screen_pan_locked_,
                    MRB_ARGS_NONE());
  mrb_define_method(M, screen, "panning?", Game__Screen_panning_,
                    MRB_ARGS_NONE());
  mrb_define_method(M, screen, "fade_level", Game__Screen_fade_level,
                    MRB_ARGS_NONE());
  mrb_define_method(M, screen, "fade_transition", Game__Screen_fade_transition,
                    MRB_ARGS_NONE());
  mrb_define_method(M, screen, "transition", Game__Screen_transition,
                    MRB_ARGS_NONE());
  mrb_define_method(M, screen, "fading?", Game__Screen_fading_,
                    MRB_ARGS_NONE());
  mrb_define_method(M, screen, "erased?", Game__Screen_erased_,
                    MRB_ARGS_NONE());
  mrb_define_method(M, screen, "busy?", Game__Screen_busy_, MRB_ARGS_NONE());
  mrb_define_method(M, screen, "tint_to", Game__Screen_tint_to,
                    MRB_ARGS_REQ(5));
  mrb_define_method(M, screen, "tint_save_data", Game__Screen_tint_save_data,
                    MRB_ARGS_NONE());
  mrb_define_method(M, screen, "restore_tint", Game__Screen_restore_tint,
                    MRB_ARGS_REQ(3));
  mrb_define_method(M, screen, "shake", Game__Screen_shake, MRB_ARGS_REQ(3));
  mrb_define_method(M, screen, "shake_begin", Game__Screen_shake_begin,
                    MRB_ARGS_REQ(2));
  mrb_define_method(M, screen, "shake_end", Game__Screen_shake_end,
                    MRB_ARGS_NONE());
  mrb_define_method(M, screen, "flash", Game__Screen_flash, MRB_ARGS_REQ(5));
  mrb_define_method(M, screen, "flash_begin", Game__Screen_flash_begin,
                    MRB_ARGS_REQ(5));
  mrb_define_method(M, screen, "flash_end", Game__Screen_flash_end,
                    MRB_ARGS_NONE());
  mrb_define_method(M, screen, "pan_reset", Game__Screen_pan_reset,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, screen, "pan_lock", Game__Screen_pan_lock,
                    MRB_ARGS_NONE());
  mrb_define_method(M, screen, "pan_unlock", Game__Screen_pan_unlock,
                    MRB_ARGS_NONE());
  mrb_define_method(M, screen, "pan_clear", Game__Screen_pan_clear,
                    MRB_ARGS_NONE());
  mrb_define_method(M, screen, "pan", Game__Screen_pan, MRB_ARGS_REQ(3));
  mrb_define_method(M, screen, "update", Game__Screen_update, MRB_ARGS_NONE());

  // Everything from here down is `private` in the real interpreted source
  // (mruby-rpg2k/mrblib/game.rb: a bare `private` right before #fade_to,
  // still in effect through the end of the class body) -- flagged by
  // bc2cpp's own == compiled entry points == diagnostic exactly like
  // Game::Picture#step/#finish_move and Game::EnemyAction#int_of/#bool_of
  // above.
  mrb_define_private_method(M, screen, "fade_to", Game__Screen_fade_to,
                            MRB_ARGS_REQ(4));
  mrb_define_private_method(M, screen, "update_fade", Game__Screen_update_fade,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, screen, "update_tint", Game__Screen_update_tint,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, screen, "update_pan", Game__Screen_update_pan,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, screen, "update_shake",
                            Game__Screen_update_shake, MRB_ARGS_NONE());
  mrb_define_private_method(M, screen, "update_flash",
                            Game__Screen_update_flash, MRB_ARGS_NONE());
  mrb_define_private_method(M, screen, "approach", Game__Screen_approach,
                            MRB_ARGS_REQ(3));
  mrb_define_private_method(M, screen, "pan_step_for",
                            Game__Screen_pan_step_for, MRB_ARGS_REQ(1));

  // RPG2k::Window (docs/adr/0139's own Window follow-up,
  // mruby-rpg2k/mrblib/main.rb) -- the RPG2000-style UI window (skin/
  // frame/cursor/contents/arrow rendering via four layered Sprites in a
  // Viewport). 17 public methods, then a bare `private` (main.rb line
  // 299, in effect through the end of the class body -- confirmed
  // directly against the real source, not guessed from bc2cpp's own
  // diagnostic) makes the remaining 15 registered below private too --
  // mrb_define_private_method for all 15, the same real fix this ADR's
  // own Game::Picture #step/#finish_move bug already needed once
  // (a hand-written mrb_define_method here would silently make a private
  // method externally callable, a real observable NoMethodError-vs-
  // silently-succeeds behavior gap, not just a style nit).
  //
  // #initialize (four optional arguments), #dispose and
  // #draw_arrow_fallback (both call into a real block -- `.each(&:...)`/
  // `N.times do ... end`, BLOCK/SENDB, genuinely out of this compiler's
  // opcode scope) stay uncompiled -- flagged by bc2cpp's own
  // SKIP_UNSUPPORTED and never registered here, so they keep running
  // mruby-rpg2k's own interpreted mrblib body unchanged, the same
  // documented fallback every other unsupported method in this codebase
  // already gets.
  RClass* rpg2k = mrb_class_get(M, "RPG2k");
  RClass* window = mrb_class_get_under(M, rpg2k, "Window");
  mrb_define_method(M, window, "x=", RPG2k__Window_x_, MRB_ARGS_REQ(1));
  mrb_define_method(M, window, "y=", RPG2k__Window_y_, MRB_ARGS_REQ(1));
  mrb_define_method(M, window, "z=", RPG2k__Window_z_, MRB_ARGS_REQ(1));
  mrb_define_method(M, window, "width=", RPG2k__Window_width_, MRB_ARGS_REQ(1));
  mrb_define_method(M, window, "height=", RPG2k__Window_height_,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, window, "windowskin=", RPG2k__Window_windowskin_,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, window, "transparent=", RPG2k__Window_transparent_,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, window, "contents=", RPG2k__Window_contents_,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, window, "cursor_rect=", RPG2k__Window_cursor_rect_,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, window, "active=", RPG2k__Window_active_,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, window, "visible=", RPG2k__Window_visible_,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, window, "open_animation", RPG2k__Window_open_animation,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, window, "close_animation", RPG2k__Window_close_animation,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, window, "opening?", RPG2k__Window_opening_,
                    MRB_ARGS_NONE());
  mrb_define_method(M, window, "closing?", RPG2k__Window_closing_,
                    MRB_ARGS_NONE());
  mrb_define_method(M, window, "pause=", RPG2k__Window_pause_, MRB_ARGS_REQ(1));
  mrb_define_method(M, window, "update", RPG2k__Window_update, MRB_ARGS_NONE());

  mrb_define_private_method(M, window, "update_rect", RPG2k__Window_update_rect,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, window, "allocate_skin",
                            RPG2k__Window_allocate_skin, MRB_ARGS_NONE());
  mrb_define_private_method(M, window, "position_arrow",
                            RPG2k__Window_position_arrow, MRB_ARGS_NONE());
  mrb_define_private_method(M, window, "draw_arrow", RPG2k__Window_draw_arrow,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, window, "draw_arrow_visibility",
                            RPG2k__Window_draw_arrow_visibility,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, window, "fully_open?", RPG2k__Window_fully_open_,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, window, "drawn_height",
                            RPG2k__Window_drawn_height, MRB_ARGS_NONE());
  mrb_define_private_method(M, window, "redraw_for_animation",
                            RPG2k__Window_redraw_for_animation,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, window, "draw_skin", RPG2k__Window_draw_skin,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, window, "draw_background",
                            RPG2k__Window_draw_background, MRB_ARGS_REQ(2));
  mrb_define_private_method(M, window, "draw_frame", RPG2k__Window_draw_frame,
                            MRB_ARGS_REQ(2));
  mrb_define_private_method(M, window, "draw_fallback",
                            RPG2k__Window_draw_fallback, MRB_ARGS_REQ(2));
  mrb_define_private_method(M, window, "draw_cursor", RPG2k__Window_draw_cursor,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, window, "draw_cursor_skin",
                            RPG2k__Window_draw_cursor_skin, MRB_ARGS_REQ(4));
  mrb_define_private_method(M, window, "draw_cursor_fallback",
                            RPG2k__Window_draw_cursor_fallback,
                            MRB_ARGS_REQ(4));

  // Game::Transition (docs/adr/0139's own follow-up, mruby-rpg2k/mrblib/
  // game.rb) -- RPG2000's ~38 screen transition styles (fades, block-
  // shuffle wipes, zoom, mosaic, wave, scroll-in/out, cut), modeled as pure
  // geometry/timing logic with no Graphics access of its own (Scene::Map
  // does the actual drawing). 32 of its 38 real bytecode-defined methods
  // compile clean -- see this file's own top comment for the real, narrow
  // reason the other 6 don't (BLOCK/SENDB, real Ruby block usage).
  //
  // #initialize takes 5 mandatory arguments, no opts -- unlike Game::Picture
  // /RPG2k::Window's own #initialize, it compiles clean, so (like
  // Game::Screen above) drop_unsafe_embeddings does NOT refuse to embed
  // here: 5 of Transition's own ivars (@style, @frames, @width, @height,
  // @frame -- all provably Fixnum, per bc2cpp's whole-program EMBED
  // diagnostic) are real struct fields on a `Game__Transition_ivars*` RData
  // payload, needing the same real MRB_SET_INSTANCE_TT(transition,
  // MRB_TT_DATA) call Game::Screen's own block above already established
  // the requirement for. The one other real ivar, @erase (a plain boolean
  // set once in #initialize and read by #black_alpha/#vertical_stripe_rects
  // /#horizontal_stripe_rects), stays on the ordinary dynamic iv_tbl --
  // this compiler's embedding lattice models Fixnum/Symbol, not booleans --
  // mixed safely with the 5 embedded fields on the very same object, same
  // as Game::Screen's own non-Fixnum ivars.
  //
  // A real, concrete case where the devirtualization-soundness fix
  // (compiles_clean?, this ADR's own follow-up above) actually matters for
  // this class: #block_order's own body (`@block_order ||=
  // compute_block_order`) sends :compute_block_order, a name with exactly
  // one bytecode definition anywhere (MONO) -- but #compute_block_order
  // itself is one of the 6 methods that doesn't compile (BLOCK/SENDB), so
  // compiles_clean? correctly refuses to devirtualize that call; the
  // generated #block_order body below falls back to ordinary mrb_funcall
  // instead of referencing a Game__Transition_compute_block_order_impl
  // symbol this run never emits -- confirmed directly against the real
  // generated output, not just reasoned about.
  //
  // Every method below is `private` in the real interpreted source *except*
  // the first 16 (a bare `private` sits right before #block_rects, still in
  // effect through the end of the class body -- confirmed directly against
  // the real source, not guessed from bc2cpp's own diagnostic) --
  // mrb_define_private_method for all of them, the same real fix this ADR's
  // own Game::Picture #step/#finish_move bug already needed once.
  RClass* transition = mrb_class_get_under(M, game, "Transition");
  MRB_SET_INSTANCE_TT(transition, MRB_TT_DATA);

  // #initialize is always private (the same real interpreter special case
  // as Game::EnemyAction#initialize/Game::Screen#initialize above -- mruby's
  // own src/class.c forces it regardless of source, not a bare `private`
  // call here).
  mrb_define_private_method(M, transition, "initialize",
                            Game__Transition_initialize, MRB_ARGS_REQ(5));
  mrb_define_method(M, transition, "done?", Game__Transition_done_,
                    MRB_ARGS_NONE());
  mrb_define_method(M, transition, "advance", Game__Transition_advance,
                    MRB_ARGS_NONE());
  mrb_define_method(M, transition, "uniform?", Game__Transition_uniform_,
                    MRB_ARGS_NONE());
  mrb_define_method(M, transition, "black_alpha", Game__Transition_black_alpha,
                    MRB_ARGS_NONE());
  mrb_define_method(M, transition, "visible_rects",
                    Game__Transition_visible_rects, MRB_ARGS_NONE());
  mrb_define_method(M, transition, "captured?", Game__Transition_captured_,
                    MRB_ARGS_NONE());
  mrb_define_method(M, transition, "zoom?", Game__Transition_zoom_,
                    MRB_ARGS_NONE());
  mrb_define_method(M, transition, "mosaic?", Game__Transition_mosaic_,
                    MRB_ARGS_NONE());
  mrb_define_method(M, transition, "wave?", Game__Transition_wave_,
                    MRB_ARGS_NONE());
  mrb_define_method(M, transition, "mosaic_block_size",
                    Game__Transition_mosaic_block_size, MRB_ARGS_NONE());
  mrb_define_method(M, transition, "wave_params", Game__Transition_wave_params,
                    MRB_ARGS_NONE());
  mrb_define_method(M, transition, "capture_ops", Game__Transition_capture_ops,
                    MRB_ARGS_NONE());
  mrb_define_method(M, transition, "random_blocks?",
                    Game__Transition_random_blocks_, MRB_ARGS_NONE());
  mrb_define_method(M, transition, "new_block_rects",
                    Game__Transition_new_block_rects, MRB_ARGS_NONE());
  mrb_define_method(M, transition, "revealed_block_rects",
                    Game__Transition_revealed_block_rects, MRB_ARGS_NONE());

  // Everything from here down is `private` in the real interpreted source
  // (mruby-rpg2k/mrblib/game.rb: a bare `private` right before #block_rects,
  // still in effect through the end of the class body).
  mrb_define_private_method(M, transition, "span", Game__Transition_span,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, transition, "frame_ratio",
                            Game__Transition_frame_ratio, MRB_ARGS_NONE());
  mrb_define_private_method(M, transition, "mosaic_wave_progress",
                            Game__Transition_mosaic_wave_progress,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, transition, "scroll_offset",
                            Game__Transition_scroll_offset, MRB_ARGS_NONE());
  mrb_define_private_method(M, transition, "half", Game__Transition_half,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, transition, "vertical_split_ops",
                            Game__Transition_vertical_split_ops,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, transition, "horizontal_split_ops",
                            Game__Transition_horizontal_split_ops,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, transition, "cross_split_ops",
                            Game__Transition_cross_split_ops, MRB_ARGS_REQ(1));
  mrb_define_private_method(M, transition, "zoom_rect",
                            Game__Transition_zoom_rect, MRB_ARGS_NONE());
  mrb_define_private_method(M, transition, "border_to_center_rect",
                            Game__Transition_border_to_center_rect,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, transition, "center_to_border_rect",
                            Game__Transition_center_to_border_rect,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, transition, "around", Game__Transition_around,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, transition, "block_grid_cols",
                            Game__Transition_block_grid_cols, MRB_ARGS_NONE());
  mrb_define_private_method(M, transition, "block_count_through",
                            Game__Transition_block_count_through,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, transition, "block_shuffle_rank",
                            Game__Transition_block_shuffle_rank,
                            MRB_ARGS_REQ(2));
  mrb_define_private_method(M, transition, "block_order",
                            Game__Transition_block_order, MRB_ARGS_NONE());

  // Game::Actor (docs/adr/0139's own GETIDX/SETIDX/GETGV follow-up) -- 74
  // real methods (76 as of the Game::Party round's own full-sweep
  // re-check, which added #set_exp; down to 74 as of a later round's own
  // bc2cpp.rb compile_send fix, which correctly stopped compiling
  // #knock_out!/#restore_class -- see their own registration comments
  // below), in
  // mruby-rpg2k/mrblib/game.rb's own definition order first (the class's
  // main ~2,100-line body), then the 9 more the class reopening in
  // mruby-rpg2k/mrblib/game/battle_support.rb adds. Every one below is
  // public in the real interpreted source -- confirmed directly (not
  // guessed from bc2cpp's own diagnostic): battle_support.rb's own `class
  // Actor` reopening (lines 14-198) has no `private`/`protected` anywhere
  // in it, and game.rb's own single `private` for this class (line 3496)
  // only covers the 5 methods registered via mrb_define_private_method at
  // the end of this block below (plus #calc_exp, which still doesn't
  // compile even after this round's own RANGE_INC addition -- it also
  // uses a real Ruby block, BLOCK/SENDB, genuinely out of this compiler's
  // scope -- so it has no entry here at all, still running mruby-rpg2k's
  // own interpreted body).
  RClass* actor = mrb_class_get_under(M, game, "Actor");
  mrb_define_method(M, actor, "display_max_hp", Game__Actor_display_max_hp,
                    MRB_ARGS_NONE());
  mrb_define_method(M, actor, "display_max_mp", Game__Actor_display_max_mp,
                    MRB_ARGS_NONE());
  mrb_define_method(M, actor, "class_name", Game__Actor_class_name,
                    MRB_ARGS_NONE());
  mrb_define_method(M, actor, "set_charset", Game__Actor_set_charset,
                    MRB_ARGS_REQ(2));
  mrb_define_method(M, actor, "sprite_changed?", Game__Actor_sprite_changed_,
                    MRB_ARGS_NONE());
  mrb_define_method(M, actor, "name_changed?", Game__Actor_name_changed_,
                    MRB_ARGS_NONE());
  mrb_define_method(M, actor, "title_changed?", Game__Actor_title_changed_,
                    MRB_ARGS_NONE());
  mrb_define_method(M, actor, "total_state_count",
                    Game__Actor_total_state_count, MRB_ARGS_NONE());
  mrb_define_method(M, actor, "faceset_name", Game__Actor_faceset_name,
                    MRB_ARGS_NONE());
  mrb_define_method(M, actor, "faceset_index", Game__Actor_faceset_index,
                    MRB_ARGS_NONE());
  mrb_define_method(M, actor, "set_faceset", Game__Actor_set_faceset,
                    MRB_ARGS_REQ(2));
  mrb_define_method(M, actor, "knows_skill?", Game__Actor_knows_skill_,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, actor, "learn_skill", Game__Actor_learn_skill,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, actor, "forget_skill", Game__Actor_forget_skill,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, actor, "dead?", Game__Actor_dead_, MRB_ARGS_NONE());
  mrb_define_method(M, actor, "state?", Game__Actor_state_, MRB_ARGS_REQ(1));
  mrb_define_method(M, actor, "state_persists_type?",
                    Game__Actor_state_persists_type_, MRB_ARGS_REQ(1));
  mrb_define_method(M, actor, "equipped?", Game__Actor_equipped_,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, actor, "free_two_handed_slot",
                    Game__Actor_free_two_handed_slot, MRB_ARGS_REQ(1));
  mrb_define_method(M, actor, "recompute_stats", Game__Actor_recompute_stats,
                    MRB_ARGS_NONE());
  mrb_define_method(M, actor, "rpg2003?", Game__Actor_rpg2003_,
                    MRB_ARGS_NONE());
  mrb_define_method(M, actor, "max_hp_cap", Game__Actor_max_hp_cap,
                    MRB_ARGS_NONE());
  mrb_define_method(M, actor, "dual_attack?", Game__Actor_dual_attack_,
                    MRB_ARGS_NONE());
  mrb_define_method(M, actor, "weapon_attack_multiplier",
                    Game__Actor_weapon_attack_multiplier, MRB_ARGS_REQ(1));
  mrb_define_method(M, actor, "swing_weapon_data",
                    Game__Actor_swing_weapon_data, MRB_ARGS_REQ(1));
  mrb_define_method(M, actor, "half_sp_cost?", Game__Actor_half_sp_cost_,
                    MRB_ARGS_NONE());
  mrb_define_method(M, actor, "prevents_terrain_damage?",
                    Game__Actor_prevents_terrain_damage_, MRB_ARGS_NONE());
  mrb_define_method(M, actor, "strong_defence?", Game__Actor_strong_defence_,
                    MRB_ARGS_NONE());
  mrb_define_method(M, actor, "force_ai?", Game__Actor_force_ai_,
                    MRB_ARGS_NONE());
  mrb_define_method(M, actor, "double_hand?", Game__Actor_double_hand_,
                    MRB_ARGS_NONE());
  mrb_define_method(M, actor, "equipment_fixed?", Game__Actor_equipment_fixed_,
                    MRB_ARGS_NONE());
  mrb_define_method(M, actor, "slot_cursed?", Game__Actor_slot_cursed_,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, actor, "exp_max", Game__Actor_exp_max, MRB_ARGS_NONE());
  mrb_define_method(M, actor, "max_level", Game__Actor_max_level,
                    MRB_ARGS_NONE());
  mrb_define_method(M, actor, "exp_for_level", Game__Actor_exp_for_level,
                    MRB_ARGS_REQ(1));
  // #set_exp is the one method this round's own full-sweep re-check (see
  // this file's own top comment -- the Game::Party round, docs/adr/0139)
  // newly unblocks here: its own `new_level -= 1 while ...` post-condition
  // loop needed SUBILV, an opcode added for a completely different class
  // (Game::Party#skill_to_hit). 76 of Game::Actor's own real methods
  // compile clean now, not 75.
  mrb_define_method(M, actor, "set_exp", Game__Actor_set_exp, MRB_ARGS_REQ(1));
  mrb_define_method(M, actor, "gain_exp", Game__Actor_gain_exp,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, actor, "next_level_exp", Game__Actor_next_level_exp,
                    MRB_ARGS_NONE());
  mrb_define_method(M, actor, "exp_to_next", Game__Actor_exp_to_next,
                    MRB_ARGS_NONE());
  mrb_define_method(M, actor, "change_level_by", Game__Actor_change_level_by,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, actor, "crit_chance", Game__Actor_crit_chance,
                    MRB_ARGS_NONE());
  mrb_define_method(M, actor, "weapon_crit_chance",
                    Game__Actor_weapon_crit_chance, MRB_ARGS_REQ(1));
  mrb_define_method(M, actor, "set_hp", Game__Actor_set_hp, MRB_ARGS_REQ(1));
  // #knock_out! is NOT registered here -- tools/bc2cpp/bc2cpp.rb's own
  // compile_send fix (see that file's top comment on the real,
  // already-shipped `Game::States.prune(ids, table, keep: permanent_states)`
  // bug this caught) now correctly refuses to compile a body containing a
  // keyword-argument call site instead of silently dropping the keyword
  // hash, so #knock_out! (its own body calls `prune(..., keep:
  // permanent_states)`) no longer compiles clean and is no longer emitted
  // -- it stays on the interpreter, mruby-rpg2k's own mrblib, the same
  // established fallback every other unsupported shape here already gets.
  mrb_define_method(M, actor, "state_table", Game__Actor_state_table,
                    MRB_ARGS_NONE());
  mrb_define_method(M, actor, "change_mp", Game__Actor_change_mp,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, actor, "change_param", Game__Actor_change_param,
                    MRB_ARGS_REQ(2));
  mrb_define_method(M, actor, "base_param_limit", Game__Actor_base_param_limit,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, actor, "battle_commands", Game__Actor_battle_commands,
                    MRB_ARGS_NONE());
  mrb_define_method(M, actor, "battle_command_row",
                    Game__Actor_battle_command_row, MRB_ARGS_REQ(1));
  // #restore_class is NOT registered here for the same reason #knock_out!
  // above isn't -- its own body calls `set_level(@level, preserve_mod:
  // false)`, a real keyword-argument call site bc2cpp's own compile_send fix
  // now correctly refuses to compile rather than silently dropping the
  // keyword (the dropped default, `preserve_mod: true`, was never what this
  // real call site actually meant).
  mrb_define_method(M, actor, "class_changed?", Game__Actor_class_changed_,
                    MRB_ARGS_NONE());
  mrb_define_method(M, actor, "battle_row", Game__Actor_battle_row,
                    MRB_ARGS_NONE());
  mrb_define_method(M, actor, "battle_row=", Game__Actor_battle_row_,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, actor, "atb_gauge", Game__Actor_atb_gauge,
                    MRB_ARGS_NONE());
  mrb_define_method(M, actor, "battle_commands=", Game__Actor_battle_commands_,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, actor, "battle_commands_changed?",
                    Game__Actor_battle_commands_changed_, MRB_ARGS_NONE());
  mrb_define_method(M, actor, "set_battle_combo", Game__Actor_set_battle_combo,
                    MRB_ARGS_REQ(2));
  mrb_define_method(M, actor, "rename_skill?", Game__Actor_rename_skill_,
                    MRB_ARGS_NONE());
  mrb_define_method(M, actor, "battle_x", Game__Actor_battle_x,
                    MRB_ARGS_NONE());
  mrb_define_method(M, actor, "battle_y", Game__Actor_battle_y,
                    MRB_ARGS_NONE());
  mrb_define_method(M, actor, "battler_animation_id",
                    Game__Actor_battler_animation_id, MRB_ARGS_NONE());

  // The 9 methods mruby-rpg2k/mrblib/game/battle_support.rb's own
  // `class Actor` reopening adds (see this block's own intro comment --
  // no `private` anywhere in that reopening, so all 9 are public here
  // too).
  mrb_define_method(M, actor, "alive?", Game__Actor_alive_, MRB_ARGS_NONE());
  mrb_define_method(M, actor, "attack_animation_id",
                    Game__Actor_attack_animation_id, MRB_ARGS_NONE());
  mrb_define_method(M, actor, "ignores_evasion?", Game__Actor_ignores_evasion_,
                    MRB_ARGS_NONE());
  mrb_define_method(M, actor, "attack_all?", Game__Actor_attack_all_,
                    MRB_ARGS_NONE());
  mrb_define_method(M, actor, "preemptive?", Game__Actor_preemptive_,
                    MRB_ARGS_NONE());
  mrb_define_method(M, actor, "weapon_sp_cost", Game__Actor_weapon_sp_cost,
                    MRB_ARGS_NONE());
  mrb_define_method(M, actor, "atb_gauge=", Game__Actor_atb_gauge_,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, actor, "clear_battle_combo",
                    Game__Actor_clear_battle_combo, MRB_ARGS_NONE());
  mrb_define_method(M, actor, "skill_command_name",
                    Game__Actor_skill_command_name, MRB_ARGS_NONE());

  // Everything from here down is `private` in the real interpreted source
  // (mruby-rpg2k/mrblib/game.rb line 3496, in effect through the end of
  // the class body) -- mrb_define_private_method for all 5, the same
  // real fix this ADR's own Game::Picture #step/#finish_move bug already
  // needed once (a hand-written mrb_define_method here would silently
  // make a private method externally callable).
  mrb_define_private_method(M, actor, "class_battle_commands",
                            Game__Actor_class_battle_commands, MRB_ARGS_NONE());
  mrb_define_private_method(M, actor, "db_exp_param", Game__Actor_db_exp_param,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, actor, "curve_row", Game__Actor_curve_row,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, actor, "set_class_id", Game__Actor_set_class_id,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, actor, "class_row_for",
                            Game__Actor_class_row_for, MRB_ARGS_REQ(1));

  // Game::Party (docs/adr/0139's own Game::Party follow-up, see this file's
  // own top comment for the full opcode/bug-fix story) -- party-wide item/
  // skill usability rules, equip/swap logic, skill damage formulas, state/
  // status application, battle placement (mruby-rpg2k/mrblib/game.rb's own
  // ~2,300-line class body, plus a second reopening in mruby-rpg2k/mrblib/
  // game/battle_support.rb). 85 of its own 128 real bytecode-defined
  // methods compile clean, in mruby-rpg2k/mrblib/game.rb's own definition
  // order first, then the 16 the battle_support.rb reopening adds.
  //
  // Visibility: exactly one real method here is private --
  // #swap_equipment_through_bag, via a real retroactive `private
  // :swap_equipment_through_bag` call right after its own def (game.rb) --
  // mrb_define_private_method for it, the same real fix this ADR's own
  // Game::Picture #step/#finish_move bug already established. Every other
  // real method registered below (including all 16 from the
  // battle_support.rb reopening, which has no `private`/`protected`
  // anywhere in its own Party section) is genuinely public in the real
  // interpreted source -- confirmed directly, not guessed from bc2cpp's
  // own diagnostic.
  //
  // 43 real methods stay interpreted, none of them a further opcode gap
  // worth chasing: 17 take an optional/rest/keyword/block argument
  // (#initialize itself among them -- `ids = nil, roster = nil` -- plus
  // #each, #gain_item, #lose_item, #field_usable?, #field_items,
  // #equip_candidates, #equip_from_bag, #field_skills, #field_skill?,
  // #cast_escape_skill, #cast_teleport_skill, #cast_switch_skill,
  // #skill_effective?, #cast_skill, #use_item, #battle_skill_command),
  // outside this compiler's pure-mandatory-argument calling convention by
  // design; 25 use a real Ruby block (BLOCK/SENDB -- #to_h, #load_state,
  // #each-based helpers, #apply_map_step_damage/#apply_terrain_damage,
  // #reorder/#toggle_actor_row/#remove_actor, the #use_medicine/#use_seed/
  // #has_item?/#equipped_item_count/#item_effective?/#item_state_ids/
  // #skill_state_ids/#weapon_attribute_ready?/#unequip_to_bag/
  // #insert_item_in_bag family, and the battle_support.rb reopening's own
  // #hit_modifier/#stat_mode/#do_nothing_restricted?/#skill_helps_troop?/
  // #battle_skills/#skill_attributes/#skill_stat_mod_keys/#battle_items),
  // the same genuinely-out-of-scope shape this file's own Game::Transition/
  // RPG2k::Window blocks already document; and #equip_by_class? alone uses
  // real exception handling (EXCEPT/RESCUE/RAISEIF), tied to mruby's own
  // setjmp/longjmp-based catch-handler machinery -- a materially bigger
  // feature than a mechanical opcode translation, correctly left alone
  // rather than forced, matching this compiler's own established RESCUE/
  // RAISEIF/EXCEPT precedent from Game::Actor's own round.
  RClass* party = mrb_class_get_under(M, game, "Party");
  mrb_define_method(M, party, "apply_actor_meta", Game__Party_apply_actor_meta,
                    MRB_ARGS_REQ(2));
  mrb_define_method(M, party, "size", Game__Party_size, MRB_ARGS_NONE());
  mrb_define_method(M, party, "leader", Game__Party_leader, MRB_ARGS_NONE());
  mrb_define_method(M, party, "take_leader_graphic_dirty",
                    Game__Party_take_leader_graphic_dirty, MRB_ARGS_NONE());
  mrb_define_method(M, party, "include_actor?", Game__Party_include_actor_,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, party, "actor_by_id", Game__Party_actor_by_id,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, party, "any_alive?", Game__Party_any_alive_,
                    MRB_ARGS_NONE());
  mrb_define_method(M, party, "all_dead?", Game__Party_all_dead_,
                    MRB_ARGS_NONE());
  mrb_define_method(M, party, "map_step_damaged?",
                    Game__Party_map_step_damaged_, MRB_ARGS_NONE());
  mrb_define_method(M, party, "add_actor", Game__Party_add_actor,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, party, "promote_to_leader",
                    Game__Party_promote_to_leader, MRB_ARGS_REQ(1));
  mrb_define_method(M, party, "item_count", Game__Party_item_count,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, party, "gain_gold", Game__Party_gain_gold,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, party, "db_item", Game__Party_db_item, MRB_ARGS_REQ(1));
  mrb_define_method(M, party, "db_enemy_group", Game__Party_db_enemy_group,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, party, "rpg2003?", Game__Party_rpg2003_,
                    MRB_ARGS_NONE());
  mrb_define_method(M, party, "alternate_battle_layout?",
                    Game__Party_alternate_battle_layout_, MRB_ARGS_NONE());
  mrb_define_method(M, party, "death_handler?", Game__Party_death_handler_,
                    MRB_ARGS_NONE());
  mrb_define_method(M, party, "death_handler_event",
                    Game__Party_death_handler_event, MRB_ARGS_NONE());
  mrb_define_method(M, party, "death_handler_teleport",
                    Game__Party_death_handler_teleport, MRB_ARGS_NONE());
  mrb_define_method(M, party, "use_skill_item_usable?",
                    Game__Party_use_skill_item_usable_, MRB_ARGS_REQ(2));
  mrb_define_method(M, party, "item_field_occasion?",
                    Game__Party_item_field_occasion_, MRB_ARGS_REQ(1));
  mrb_define_method(M, party, "item_battle_occasion?",
                    Game__Party_item_battle_occasion_, MRB_ARGS_REQ(1));
  mrb_define_method(M, party, "item_field_only?", Game__Party_item_field_only_,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, party, "switch_item?", Game__Party_switch_item_,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, party, "use_switch_item", Game__Party_use_switch_item,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, party, "item_recovery", Game__Party_item_recovery,
                    MRB_ARGS_REQ(2));
  mrb_define_method(M, party, "item_cured_states",
                    Game__Party_item_cured_states, MRB_ARGS_REQ(1));
  mrb_define_method(M, party, "ko_only_blocked?", Game__Party_ko_only_blocked_,
                    MRB_ARGS_REQ(2));
  mrb_define_method(M, party, "item_usable_by?", Game__Party_item_usable_by_,
                    MRB_ARGS_REQ(2));
  mrb_define_method(M, party, "item_usable_by_class?",
                    Game__Party_item_usable_by_class_, MRB_ARGS_REQ(2));
  mrb_define_method(M, party, "item_uses", Game__Party_item_uses,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, party, "consume_item_use", Game__Party_consume_item_use,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, party, "use_special_item", Game__Party_use_special_item,
                    MRB_ARGS_REQ(3));
  mrb_define_method(M, party, "use_equip_skill_item",
                    Game__Party_use_equip_skill_item, MRB_ARGS_REQ(3));
  mrb_define_method(M, party, "use_special_escape_item",
                    Game__Party_use_special_escape_item, MRB_ARGS_REQ(3));
  mrb_define_method(M, party, "use_special_teleport_item",
                    Game__Party_use_special_teleport_item, MRB_ARGS_REQ(4));
  mrb_define_method(M, party, "use_special_switch_item",
                    Game__Party_use_special_switch_item, MRB_ARGS_REQ(2));
  mrb_define_method(M, party, "use_skill_book", Game__Party_use_skill_book,
                    MRB_ARGS_REQ(3));
  mrb_define_method(M, party, "seed_boosts", Game__Party_seed_boosts,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, party, "equip_slot_for", Game__Party_equip_slot_for,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, party, "equip_candidate_for?",
                    Game__Party_equip_candidate_for_, MRB_ARGS_REQ(3));
  mrb_define_private_method(M, party, "swap_equipment_through_bag",
                            Game__Party_swap_equipment_through_bag,
                            MRB_ARGS_REQ(3));
  mrb_define_method(M, party, "equip_item_from_bag",
                    Game__Party_equip_item_from_bag, MRB_ARGS_REQ(2));
  mrb_define_method(M, party, "db_skill", Game__Party_db_skill,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, party, "term", Game__Party_term, MRB_ARGS_REQ(1));
  mrb_define_method(M, party, "state_table", Game__Party_state_table,
                    MRB_ARGS_NONE());
  mrb_define_method(M, party, "skill_cost", Game__Party_skill_cost,
                    MRB_ARGS_REQ(2));
  mrb_define_method(M, party, "escape_skill_available?",
                    Game__Party_escape_skill_available_, MRB_ARGS_REQ(1));
  mrb_define_method(M, party, "teleport_skill_available?",
                    Game__Party_teleport_skill_available_, MRB_ARGS_REQ(1));
  mrb_define_method(M, party, "flying?", Game__Party_flying_, MRB_ARGS_REQ(1));
  mrb_define_method(M, party, "unsupported_field_skill?",
                    Game__Party_unsupported_field_skill_, MRB_ARGS_REQ(1));
  mrb_define_method(M, party, "field_occasion?", Game__Party_field_occasion_,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, party, "switch_skill?", Game__Party_switch_skill_,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, party, "can_cast?", Game__Party_can_cast_,
                    MRB_ARGS_REQ(2));
  mrb_define_method(M, party, "attribute_weapon_type?",
                    Game__Party_attribute_weapon_type_, MRB_ARGS_REQ(1));
  mrb_define_method(M, party, "adjust_stat", Game__Party_adjust_stat,
                    MRB_ARGS_REQ(2));
  mrb_define_method(M, party, "modified_stat", Game__Party_modified_stat,
                    MRB_ARGS_REQ(3));
  mrb_define_method(M, party, "effective_atk", Game__Party_effective_atk,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, party, "effective_int", Game__Party_effective_int,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, party, "effective_def", Game__Party_effective_def,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, party, "effective_spi", Game__Party_effective_spi,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, party, "effective_agi", Game__Party_effective_agi,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, party, "skill_effect", Game__Party_skill_effect,
                    MRB_ARGS_REQ(2));
  mrb_define_method(M, party, "skill_defence_term",
                    Game__Party_skill_defence_term, MRB_ARGS_REQ(2));
  mrb_define_method(M, party, "skill_ignores_defence?",
                    Game__Party_skill_ignores_defence_, MRB_ARGS_REQ(1));
  mrb_define_method(M, party, "skill_targets", Game__Party_skill_targets,
                    MRB_ARGS_REQ(3));
  mrb_define_method(M, party, "skill_cured_states",
                    Game__Party_skill_cured_states, MRB_ARGS_REQ(1));
  mrb_define_method(M, party, "skill_inflicted_states",
                    Game__Party_skill_inflicted_states, MRB_ARGS_REQ(1));
  mrb_define_method(M, party, "gauge_battle_layout?",
                    Game__Party_gauge_battle_layout_, MRB_ARGS_NONE());
  mrb_define_method(M, party, "automatic_battle_placement?",
                    Game__Party_automatic_battle_placement_, MRB_ARGS_NONE());
  mrb_define_method(M, party, "battle_skill?", Game__Party_battle_skill_,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, party, "battle_occasion?", Game__Party_battle_occasion_,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, party, "battle_skill_target",
                    Game__Party_battle_skill_target, MRB_ARGS_REQ(1));
  mrb_define_method(M, party, "skill_absorbs?", Game__Party_skill_absorbs_,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, party, "skill_hit", Game__Party_skill_hit,
                    MRB_ARGS_REQ(2));
  mrb_define_method(M, party, "skill_hit_weapon_fallback",
                    Game__Party_skill_hit_weapon_fallback, MRB_ARGS_REQ(1));
  mrb_define_method(M, party, "skill_to_hit", Game__Party_skill_to_hit,
                    MRB_ARGS_REQ(3));
  mrb_define_method(M, party, "state_hit_ratio", Game__Party_state_hit_ratio,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, party, "skill_variance", Game__Party_skill_variance,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, party, "skill_attr_shift", Game__Party_skill_attr_shift,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, party, "skill_invoking_item?",
                    Game__Party_skill_invoking_item_, MRB_ARGS_REQ(1));
  mrb_define_method(M, party, "battle_usable?", Game__Party_battle_usable_,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, party, "battle_item_command",
                    Game__Party_battle_item_command, MRB_ARGS_REQ(2));
  mrb_define_method(M, party, "item_all_allies?", Game__Party_item_all_allies_,
                    MRB_ARGS_REQ(1));

  // RPG2k::Scene::MapViewer (docs/adr/0139's own follow-up,
  // mruby-rpg2k/mrblib/scene/map_viewer.rb) -- the F9 debug-menu map
  // overview/editor scene. 34 of its 42 real bytecode-defined methods
  // compile clean. #initialize (four keyword arguments, all optional --
  // `map: nil, start_mode: :pan, quit_on_close: false`) stays interpreted,
  // the same non-mandatory-arity gap as Game::Picture/RPG2k::Window/
  // Game::Actor's own #initialize above -- so (like those three, and
  // unlike Game::Screen/Game::Transition) bc2cpp's own drop_unsafe_embeddings
  // guard refuses to embed any of this class's own provably-typed ivars
  // (@mode/@brush_layer: Symbol; @brush/@ox/@oy: Fixnum, per the
  // whole-program EMBED diagnostic) into an RData struct -- every ivar
  // access below still goes through the ordinary dynamic iv_tbl, no
  // MRB_SET_INSTANCE_TT call needed here, confirmed directly against the
  // real generated output the same way as Game::Picture/RPG2k::Window's own
  // top-of-file comment already documents.
  //
  // 7 more stay interpreted for real, narrow, out-of-scope reasons, not
  // guessed: #build_chipset and #save_to_disk each have a real `rescue
  // StandardError => e` clause (RESCUE/RAISEIF/EXCEPT, plus RETURN_BLK for
  // build_chipset's own early `return nil unless @map`-then-rescue shape);
  // #event_at, #draw_tiles, #draw_tile_row, #draw_events and
  // #each_event_position all use a real Ruby block (`each_event_position {
  // |...| ... }`/`(0...n).each do |...| ... end`, BLOCK/S(S)END, and
  // #draw_tiles/#draw_tile_row's own exclusive Range literals need
  // RANGE_EXC too) -- the same established out-of-scope shape every other
  // compiled target's own block-using methods already stay interpreted for
  // (RPG2k::Window#dispose/#draw_arrow_fallback, Game::Transition's own 6).
  //
  // Every method below is `private` in the real interpreted source *except*
  // the first 2 (#update, #dispose -- map_viewer.rb's own single `private`
  // sits right before #update_pan, line 164, in effect through the end of
  // the class body -- confirmed directly against the real source, not
  // guessed from bc2cpp's own diagnostic) -- mrb_define_private_method for
  // the other 32, the same real fix this ADR's own Game::Picture
  // #step/#finish_move bug already needed once.
  RClass* scene = mrb_module_get_under(M, rpg2k, "Scene");
  RClass* map_viewer = mrb_class_get_under(M, scene, "MapViewer");
  mrb_define_method(M, map_viewer, "update", RPG2k__Scene__MapViewer_update,
                    MRB_ARGS_NONE());
  mrb_define_method(M, map_viewer, "dispose", RPG2k__Scene__MapViewer_dispose,
                    MRB_ARGS_NONE());

  mrb_define_private_method(M, map_viewer, "update_pan",
                            RPG2k__Scene__MapViewer_update_pan,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, map_viewer, "update_select",
                            RPG2k__Scene__MapViewer_update_select,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, map_viewer, "update_edit",
                            RPG2k__Scene__MapViewer_update_edit,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, map_viewer, "close",
                            RPG2k__Scene__MapViewer_close, MRB_ARGS_NONE());
  mrb_define_private_method(M, map_viewer, "enter_select_mode",
                            RPG2k__Scene__MapViewer_enter_select_mode,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, map_viewer, "enter_edit_mode",
                            RPG2k__Scene__MapViewer_enter_edit_mode,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, map_viewer, "cursor_start",
                            RPG2k__Scene__MapViewer_cursor_start,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, map_viewer, "zoom_in",
                            RPG2k__Scene__MapViewer_zoom_in, MRB_ARGS_NONE());
  mrb_define_private_method(M, map_viewer, "zoom_out",
                            RPG2k__Scene__MapViewer_zoom_out, MRB_ARGS_NONE());
  mrb_define_private_method(M, map_viewer, "set_zoom",
                            RPG2k__Scene__MapViewer_set_zoom, MRB_ARGS_REQ(1));
  mrb_define_private_method(M, map_viewer, "recompute_view",
                            RPG2k__Scene__MapViewer_recompute_view,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, map_viewer, "paint_cursor",
                            RPG2k__Scene__MapViewer_paint_cursor,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, map_viewer, "pick_brush",
                            RPG2k__Scene__MapViewer_pick_brush,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, map_viewer, "move_cursor",
                            RPG2k__Scene__MapViewer_move_cursor,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, map_viewer, "ensure_cursor_visible",
                            RPG2k__Scene__MapViewer_ensure_cursor_visible,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, map_viewer, "scroll_to_fit",
                            RPG2k__Scene__MapViewer_scroll_to_fit,
                            MRB_ARGS_REQ(3));
  mrb_define_private_method(M, map_viewer, "teleport_to_cursor",
                            RPG2k__Scene__MapViewer_teleport_to_cursor,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, map_viewer, "pan", RPG2k__Scene__MapViewer_pan,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, map_viewer, "max_ox",
                            RPG2k__Scene__MapViewer_max_ox, MRB_ARGS_NONE());
  mrb_define_private_method(M, map_viewer, "max_oy",
                            RPG2k__Scene__MapViewer_max_oy, MRB_ARGS_NONE());
  mrb_define_private_method(M, map_viewer, "center_on_player",
                            RPG2k__Scene__MapViewer_center_on_player,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, map_viewer, "clamp",
                            RPG2k__Scene__MapViewer_clamp, MRB_ARGS_REQ(3));
  mrb_define_private_method(M, map_viewer, "refresh",
                            RPG2k__Scene__MapViewer_refresh, MRB_ARGS_NONE());
  mrb_define_private_method(M, map_viewer, "draw_header",
                            RPG2k__Scene__MapViewer_draw_header,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, map_viewer, "player_header_text",
                            RPG2k__Scene__MapViewer_player_header_text,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, map_viewer, "select_header_text",
                            RPG2k__Scene__MapViewer_select_header_text,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, map_viewer, "edit_header_text",
                            RPG2k__Scene__MapViewer_edit_header_text,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, map_viewer, "draw_footer",
                            RPG2k__Scene__MapViewer_draw_footer,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, map_viewer, "tile_color",
                            RPG2k__Scene__MapViewer_tile_color,
                            MRB_ARGS_REQ(2));
  mrb_define_private_method(M, map_viewer, "draw_player",
                            RPG2k__Scene__MapViewer_draw_player,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, map_viewer, "mark", RPG2k__Scene__MapViewer_mark,
                            MRB_ARGS_REQ(3));
  mrb_define_private_method(M, map_viewer, "draw_cursor",
                            RPG2k__Scene__MapViewer_draw_cursor,
                            MRB_ARGS_NONE());

  // Game::Battle (docs/adr/0139's own follow-up, mruby-rpg2k/mrblib/
  // game/battle.rb) -- the headless turn-based/gauge combat-resolution
  // engine (turn order, command resolution, hit/damage/state-infliction
  // formulas, enemy AI action selection). 72 of its own 141 real
  // bytecode-defined methods compile clean (75 as first shipped; down to
  // 72 as of a later round's own bc2cpp.rb compile_send fix, which
  // correctly stopped compiling #enemy_basic_action/#enemy_fallback_attack/
  // #inflict_state -- see their own registration comments below), needing
  // no new opcode work at all -- see this file's own top comment for the
  // full accounting of the other gaps (non-mandatory arguments or a
  // genuine Ruby block, plus the one real #apply_knockout_reset near-miss
  // that still ends in a block regardless of its own separate SYMBOL-opcode
  // gap).
  //
  // Visibility: a single bare `private` (battle.rb line 1720) makes
  // everything from #do_nothing_restricted? on private by default, but
  // three names are retroactively reopened public right after their own
  // def (`public :do_nothing_restricted?` / `public
  // :choose_auto_battle_command` / `public :inflict_state, :cure_state,
  // :apply_knockout_reset`) -- confirmed directly against the real
  // source, not guessed from bc2cpp's own diagnostic. Of those three only
  // #cure_state actually compiles (#do_nothing_restricted?/
  // #choose_auto_battle_command/#apply_knockout_reset all hit the same
  // BLOCK/SENDB gap; #inflict_state used to compile too, but no longer
  // does since bc2cpp's own compile_send fix -- see this block's own
  // #inflict_state registration comment below for why), so it is
  // registered with plain mrb_define_method below despite sitting after
  // the `private` line -- bc2cpp's own visibility tracking (which models
  // exactly this mode-switch-plus-retroactive-reopen shape) confirms it,
  // the same real fix this ADR's own Game::Picture #step/#finish_move bug
  // already established the need for.
  //
  // #initialize itself (`states: nil, variance: false, ...`, a mix of
  // optional positional and keyword arguments) stays interpreted, the
  // same non-mandatory-arity gap as Picture's/Window's/Actor's/Party's/
  // MapViewer's own #initialize -- so its own two provably-Fixnum ivars
  // (@battle_type, @rounds -- per the whole-program EMBED diagnostic)
  // stay unembedded too, no MRB_SET_INSTANCE_TT call needed here,
  // confirmed directly against the real generated output (Game::Battle
  // does not appear in bc2cpp's own "classes needing
  // MRB_SET_INSTANCE_TT(..., MRB_TT_DATA)" diagnostic).
  RClass* battle = mrb_class_get_under(M, game, "Battle");
  mrb_define_method(M, battle, "damage_cap", Game__Battle_damage_cap,
                    MRB_ARGS_NONE());
  mrb_define_method(M, battle, "recover_cap", Game__Battle_recover_cap,
                    MRB_ARGS_NONE());
  mrb_define_method(M, battle, "finished?", Game__Battle_finished_,
                    MRB_ARGS_NONE());
  mrb_define_method(M, battle, "escaped?", Game__Battle_escaped_,
                    MRB_ARGS_NONE());
  mrb_define_method(M, battle, "turn", Game__Battle_turn, MRB_ARGS_NONE());
  mrb_define_method(M, battle, "acting_battler", Game__Battle_acting_battler,
                    MRB_ARGS_NONE());
  mrb_define_method(M, battle, "enemy", Game__Battle_enemy, MRB_ARGS_REQ(1));
  mrb_define_method(M, battle, "rpg2003?", Game__Battle_rpg2003_,
                    MRB_ARGS_NONE());
  mrb_define_method(M, battle, "force_flee_party",
                    Game__Battle_force_flee_party, MRB_ARGS_NONE());
  mrb_define_method(M, battle, "force_flee?", Game__Battle_force_flee_,
                    MRB_ARGS_NONE());
  mrb_define_method(M, battle, "flee_enemy", Game__Battle_flee_enemy,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, battle, "terminate", Game__Battle_terminate,
                    MRB_ARGS_NONE());
  mrb_define_method(M, battle, "terminated?", Game__Battle_terminated_,
                    MRB_ARGS_NONE());
  mrb_define_method(M, battle, "run", Game__Battle_run, MRB_ARGS_NONE());
  mrb_define_method(M, battle, "command_attack", Game__Battle_command_attack,
                    MRB_ARGS_REQ(2));
  mrb_define_method(M, battle, "command_defend", Game__Battle_command_defend,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, battle, "command_skip", Game__Battle_command_skip,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, battle, "toggle_row", Game__Battle_toggle_row,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, battle, "compute_escape_chance",
                    Game__Battle_compute_escape_chance, MRB_ARGS_NONE());
  mrb_define_method(M, battle, "first_strike?", Game__Battle_first_strike_,
                    MRB_ARGS_NONE());
  mrb_define_method(M, battle, "row_adjusted?", Game__Battle_row_adjusted_,
                    MRB_ARGS_REQ(2));
  mrb_define_method(M, battle, "all_combatants", Game__Battle_all_combatants,
                    MRB_ARGS_NONE());
  mrb_define_method(M, battle, "reset_gauge", Game__Battle_reset_gauge,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, battle, "pop_ready", Game__Battle_pop_ready,
                    MRB_ARGS_NONE());
  mrb_define_method(M, battle, "begin_gauge_turn",
                    Game__Battle_begin_gauge_turn, MRB_ARGS_REQ(1));
  mrb_define_method(M, battle, "to_hit", Game__Battle_to_hit, MRB_ARGS_REQ(2));
  mrb_define_method(M, battle, "state_hit_ratio", Game__Battle_state_hit_ratio,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, battle, "adjust_stat", Game__Battle_adjust_stat,
                    MRB_ARGS_REQ(2));
  mrb_define_method(M, battle, "modified_stat", Game__Battle_modified_stat,
                    MRB_ARGS_REQ(2));
  mrb_define_method(M, battle, "effective_atk", Game__Battle_effective_atk,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, battle, "effective_def", Game__Battle_effective_def,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, battle, "effective_spi", Game__Battle_effective_spi,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, battle, "effective_agi", Game__Battle_effective_agi,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, battle, "run_round", Game__Battle_run_round,
                    MRB_ARGS_NONE());
  mrb_define_method(M, battle, "begin_round", Game__Battle_begin_round,
                    MRB_ARGS_NONE());
  mrb_define_method(M, battle, "pending_empty?", Game__Battle_pending_empty_,
                    MRB_ARGS_NONE());
  mrb_define_method(M, battle, "command_restricted?",
                    Game__Battle_command_restricted_, MRB_ARGS_REQ(1));

  // Everything from here down is `private` in the real interpreted source
  // (mruby-rpg2k/mrblib/game/battle.rb line 1720, in effect through the
  // end of the class body) EXCEPT #cure_state at the very end,
  // retroactively reopened public -- see this block's own intro comment
  // above.
  mrb_define_private_method(M, battle, "state_def", Game__Battle_state_def,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, battle, "ally?", Game__Battle_ally_,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, battle, "state_field", Game__Battle_state_field,
                            MRB_ARGS_REQ(2));
  mrb_define_private_method(M, battle, "slip_stat", Game__Battle_slip_stat,
                            MRB_ARGS_REQ(5));
  mrb_define_private_method(M, battle, "recovers_from_state?",
                            Game__Battle_recovers_from_state_, MRB_ARGS_REQ(3));
  mrb_define_private_method(M, battle, "preemptive_boost?",
                            Game__Battle_preemptive_boost_, MRB_ARGS_REQ(1));
  mrb_define_private_method(M, battle, "strike", Game__Battle_strike,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, battle, "pay_weapon_sp_cost",
                            Game__Battle_pay_weapon_sp_cost, MRB_ARGS_REQ(1));
  mrb_define_private_method(M, battle, "battle_command_type",
                            Game__Battle_battle_command_type, MRB_ARGS_REQ(2));
  mrb_define_private_method(M, battle, "combo_hits", Game__Battle_combo_hits,
                            MRB_ARGS_REQ(2));
  mrb_define_private_method(M, battle, "within_percent?",
                            Game__Battle_within_percent_, MRB_ARGS_REQ(3));
  mrb_define_private_method(M, battle, "enemy_skill_ready?",
                            Game__Battle_enemy_skill_ready_, MRB_ARGS_REQ(2));
  mrb_define_private_method(M, battle, "perform_enemy_action",
                            Game__Battle_perform_enemy_action, MRB_ARGS_REQ(2));
  mrb_define_private_method(M, battle, "apply_action_switches",
                            Game__Battle_apply_action_switches,
                            MRB_ARGS_REQ(1));
  // #enemy_basic_action is NOT registered here -- tools/bc2cpp/bc2cpp.rb's
  // own compile_send fix (see that file's top comment) now correctly
  // refuses to compile a body containing a keyword-argument call site
  // instead of silently dropping the keyword hash. This method's own body
  // calls `deal_attack(b, target, 0, charged: charged)` three times (a real,
  // already-shipped bug this fix caught: every charged enemy attack routed
  // through here used to call #deal_attack with its own `charged: nil`
  // default instead of the caller's real charged state) -- it no longer
  // compiles clean and is no longer emitted, staying on the interpreter.
  mrb_define_private_method(M, battle, "skill_command_hash",
                            Game__Battle_skill_command_hash, MRB_ARGS_REQ(3));
  mrb_define_private_method(M, battle, "skill_name_of",
                            Game__Battle_skill_name_of, MRB_ARGS_REQ(1));
  mrb_define_private_method(M, battle, "enemy_transform_action",
                            Game__Battle_enemy_transform_action,
                            MRB_ARGS_REQ(3));
  // #enemy_fallback_attack is NOT registered here for the same reason
  // #enemy_basic_action above isn't -- its own body also calls
  // `deal_attack(..., charged: charged)`.
  mrb_define_private_method(M, battle, "auto_battle_heal_rank",
                            Game__Battle_auto_battle_heal_rank,
                            MRB_ARGS_REQ(3));
  mrb_define_private_method(M, battle, "auto_battle_raw_cost",
                            Game__Battle_auto_battle_raw_cost, MRB_ARGS_REQ(2));
  mrb_define_private_method(M, battle, "queue_single_auto_battle_skill",
                            Game__Battle_queue_single_auto_battle_skill,
                            MRB_ARGS_REQ(4));
  mrb_define_private_method(M, battle, "critical?", Game__Battle_critical_,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, battle, "hits?", Game__Battle_hits_,
                            MRB_ARGS_REQ(2));
  mrb_define_private_method(M, battle, "skill_effect_hits?",
                            Game__Battle_skill_effect_hits_, MRB_ARGS_REQ(1));
  mrb_define_private_method(M, battle, "varied", Game__Battle_varied,
                            MRB_ARGS_REQ(2));
  mrb_define_private_method(M, battle, "attr_rate", Game__Battle_attr_rate,
                            MRB_ARGS_REQ(2));
  mrb_define_private_method(M, battle, "attribute_physical?",
                            Game__Battle_attribute_physical_, MRB_ARGS_REQ(1));
  mrb_define_private_method(M, battle, "above_attr_limit?",
                            Game__Battle_above_attr_limit_, MRB_ARGS_REQ(1));
  mrb_define_private_method(M, battle, "state_flag", Game__Battle_state_flag,
                            MRB_ARGS_REQ(2));
  mrb_define_private_method(M, battle, "restricted_target",
                            Game__Battle_restricted_target, MRB_ARGS_REQ(2));
  mrb_define_private_method(M, battle, "attack_target",
                            Game__Battle_attack_target, MRB_ARGS_REQ(1));
  mrb_define_private_method(M, battle, "command_targets_dead_ok?",
                            Game__Battle_command_targets_dead_ok_,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, battle, "state_rate", Game__Battle_state_rate,
                            MRB_ARGS_REQ(2));
  mrb_define_private_method(M, battle, "state_susceptibility",
                            Game__Battle_state_susceptibility, MRB_ARGS_REQ(2));
  mrb_define_private_method(M, battle, "combatant_permanent_states",
                            Game__Battle_combatant_permanent_states,
                            MRB_ARGS_REQ(1));
  // #inflict_state is NOT registered here for the same reason
  // #enemy_basic_action/#enemy_fallback_attack above aren't -- its own body
  // calls `Game::States.prune((target.states || []) + [sid], @states, keep:
  // combatant_permanent_states(target))`, a real keyword-argument call site
  // bc2cpp's own compile_send fix now correctly refuses to compile: the
  // dropped `keep:` argument used to mean a real permanently-protected
  // state (e.g. an innate racial trait modeled as a state) could be silently
  // pruned away as if no exemption list existed at all.
  mrb_define_method(M, battle, "cure_state", Game__Battle_cure_state,
                    MRB_ARGS_REQ(2));

  // RPG2k::Scene::ItemMenu (docs/adr/0139's own RANGE_INC/RANGE_EXC
  // opcode follow-up, mruby-rpg2k/mrblib/scene/item_menu.rb) -- the
  // field/battle item-use menu. 41 of its own 47 real bytecode-defined
  // methods compile clean, in the real source's own definition order: 7
  // public methods (#initialize itself is the one real gap, see below),
  // then a bare `private` (item_menu.rb line 198, in effect through the
  // end of the class body -- confirmed directly against the real source,
  // not guessed from bc2cpp's own diagnostic) makes the other 34
  // registered below private too -- mrb_define_private_method for all of
  // them, the same real fix this ADR's own Game::Picture #step/
  // #finish_move bug already needed once (a hand-written
  // mrb_define_method here would silently make a private method
  // externally callable).
  //
  // #initialize (`super parent`, a real SUPER opcode -- out of this
  // compiler's opcode scope) and 5 other private methods
  // (#teleport_targets/#build_teleport_window/#build_item_window/
  // #build_target_window: real Ruby block usage, BLOCK/SENDB;
  // #load_face_bitmap: a real `rescue StandardError` clause, RETURN_BLK/
  // EXCEPT/RESCUE/RAISEIF) stay uncompiled -- flagged by bc2cpp's own
  // SKIP_UNSUPPORTED and never registered here, so they keep running
  // mruby-rpg2k's own interpreted mrblib body unchanged, the same
  // documented fallback every other unsupported method in this codebase
  // already gets. Because #initialize itself never compiles,
  // drop_unsafe_embeddings correctly refuses to embed any of ItemMenu's
  // own provably-Fixnum/Symbol ivars (@mode/@item_index/@item_top/
  // @target_index/@teleport_index/@arrow_anim) into a struct -- same
  // shape as Game::Picture/RPG2k::Window/Game::Actor above, no
  // MRB_SET_INSTANCE_TT call needed here. Reuses the `scene` RClass* the
  // RPG2k::Scene::MapViewer block above already looked up -- both live
  // under the same RPG2k::Scene module.
  RClass* item_menu = mrb_class_get_under(M, scene, "ItemMenu");
  mrb_define_method(M, item_menu, "dispose", RPG2k__Scene__ItemMenu_dispose,
                    MRB_ARGS_NONE());
  mrb_define_method(M, item_menu, "update", RPG2k__Scene__ItemMenu_update,
                    MRB_ARGS_NONE());
  mrb_define_method(M, item_menu, "tick_arrows",
                    RPG2k__Scene__ItemMenu_tick_arrows, MRB_ARGS_NONE());
  mrb_define_method(M, item_menu, "refresh_arrows",
                    RPG2k__Scene__ItemMenu_refresh_arrows, MRB_ARGS_NONE());
  mrb_define_method(M, item_menu, "item_row_count",
                    RPG2k__Scene__ItemMenu_item_row_count, MRB_ARGS_NONE());
  mrb_define_method(M, item_menu, "build_arrow_sprites",
                    RPG2k__Scene__ItemMenu_build_arrow_sprites,
                    MRB_ARGS_NONE());
  mrb_define_method(M, item_menu, "build_arrow_sprite",
                    RPG2k__Scene__ItemMenu_build_arrow_sprite, MRB_ARGS_REQ(2));

  // Everything from here down is `private` in the real interpreted source
  // (mruby-rpg2k/mrblib/scene/item_menu.rb line 198, in effect through the
  // end of the class body).
  mrb_define_private_method(M, item_menu, "items", RPG2k__Scene__ItemMenu_items,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, item_menu, "invalidate_items",
                            RPG2k__Scene__ItemMenu_invalidate_items,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, item_menu, "update_items",
                            RPG2k__Scene__ItemMenu_update_items,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, item_menu, "move_item_cursor",
                            RPG2k__Scene__ItemMenu_move_item_cursor,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, item_menu, "scroll_item_list_to_cursor",
                            RPG2k__Scene__ItemMenu_scroll_item_list_to_cursor,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, item_menu, "choose_item",
                            RPG2k__Scene__ItemMenu_choose_item,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, item_menu, "prompt_item_target",
                            RPG2k__Scene__ItemMenu_prompt_item_target,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, item_menu, "enter_target_confirm",
                            RPG2k__Scene__ItemMenu_enter_target_confirm,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, item_menu, "leader_target_index",
                            RPG2k__Scene__ItemMenu_leader_target_index,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, item_menu, "apply_switch_item",
                            RPG2k__Scene__ItemMenu_apply_switch_item,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, item_menu, "apply_escape_item",
                            RPG2k__Scene__ItemMenu_apply_escape_item,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, item_menu, "apply_special_switch_item",
                            RPG2k__Scene__ItemMenu_apply_special_switch_item,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, item_menu, "apply_teleport_item",
                            RPG2k__Scene__ItemMenu_apply_teleport_item,
                            MRB_ARGS_REQ(2));
  mrb_define_private_method(M, item_menu, "queue_teleport",
                            RPG2k__Scene__ItemMenu_queue_teleport,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, item_menu, "update_teleport_target",
                            RPG2k__Scene__ItemMenu_update_teleport_target,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, item_menu, "move_teleport_cursor",
                            RPG2k__Scene__ItemMenu_move_teleport_cursor,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, item_menu, "enter_teleport_target",
                            RPG2k__Scene__ItemMenu_enter_teleport_target,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, item_menu, "leave_teleport_target",
                            RPG2k__Scene__ItemMenu_leave_teleport_target,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, item_menu, "map_display_name",
                            RPG2k__Scene__ItemMenu_map_display_name,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, item_menu, "teleport_col_w",
                            RPG2k__Scene__ItemMenu_teleport_col_w,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, item_menu, "refresh_teleport_cursor",
                            RPG2k__Scene__ItemMenu_refresh_teleport_cursor,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, item_menu, "update_target",
                            RPG2k__Scene__ItemMenu_update_target,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, item_menu, "apply_item",
                            RPG2k__Scene__ItemMenu_apply_item, MRB_ARGS_REQ(2));
  mrb_define_private_method(M, item_menu, "play_item_use_se",
                            RPG2k__Scene__ItemMenu_play_item_use_se,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, item_menu, "leave_target_mode",
                            RPG2k__Scene__ItemMenu_leave_target_mode,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, item_menu, "left_panel_w",
                            RPG2k__Scene__ItemMenu_left_panel_w,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, item_menu, "build_desc_window",
                            RPG2k__Scene__ItemMenu_build_desc_window,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, item_menu, "refresh_desc",
                            RPG2k__Scene__ItemMenu_refresh_desc,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, item_menu, "item_col_w",
                            RPG2k__Scene__ItemMenu_item_col_w, MRB_ARGS_NONE());
  mrb_define_private_method(M, item_menu, "item_col_x",
                            RPG2k__Scene__ItemMenu_item_col_x, MRB_ARGS_REQ(1));
  mrb_define_private_method(M, item_menu, "refresh_item_cursor",
                            RPG2k__Scene__ItemMenu_refresh_item_cursor,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, item_menu, "build_possessed_window",
                            RPG2k__Scene__ItemMenu_build_possessed_window,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, item_menu, "draw_target_face",
                            RPG2k__Scene__ItemMenu_draw_target_face,
                            MRB_ARGS_REQ(3));
  mrb_define_private_method(M, item_menu, "refresh_target_cursor",
                            RPG2k__Scene__ItemMenu_refresh_target_cursor,
                            MRB_ARGS_NONE());

  // RPG2k::Scene::SkillMenu (mruby-rpg2k/mrblib/scene/skill_menu.rb) -- the
  // field/battle skill-use menu (skill list scrolling/selection, target
  // selection -- including the teleport-skill map picker -- and applying a
  // chosen skill's effect). 39 of its own 46 real bytecode-defined methods
  // compile clean, needing no new opcode work at all: the opcode set six
  // rounds of this ADR have already built up already covers every real
  // shape this class's own method bodies use.
  //
  // #initialize (`actor_index = 0`, one optional argument) stays
  // interpreted, the same non-mandatory-arity gap as Game::Picture/
  // RPG2k::Window/Game::Actor/Game::Party/RPG2k::Scene::MapViewer's own
  // #initialize above -- so, like those five, bc2cpp's own
  // drop_unsafe_embeddings guard refuses to embed any of this class's own
  // 6 real provably-Fixnum ivars (@caster_index, @skill_index, @top_row,
  // @arrow_anim, @target_index, @teleport_index) into an RData struct:
  // every ivar access below still goes through the ordinary dynamic
  // iv_tbl, no MRB_SET_INSTANCE_TT call needed here -- confirmed directly
  // against the real generated output, the same way as every other
  // non-embedding target's own top-of-file comment already documents.
  //
  // The 7 methods that stay interpreted are genuinely out of this
  // prototype's scope, not a missing opcode -- confirmed against the real
  // generated `#error` markers, not guessed: #load_face_bitmap and
  // #play_skill_sound_effect each have a real `rescue StandardError => e`
  // clause (RESCUE/RAISEIF/EXCEPT); #draw_skill_rows, #build_target_window,
  // #teleport_targets and #build_teleport_window each use a real Ruby block
  // (`.each { |...| ... }`/`N.times do ... end`, BLOCK/SENDB) -- the same
  // established out-of-scope shapes every other compiled target's own
  // rescue/block-using methods already stay interpreted for.
  //
  // Every method below is `private` in the real interpreted source except
  // the first 2 (#update, #dispose -- skill_menu.rb's own single `private`
  // sits right before #caster, line 173, in effect through the end of the
  // class body -- confirmed directly against the real source, not guessed
  // from bc2cpp's own diagnostic) -- mrb_define_private_method for the
  // other 37, the same real fix this ADR's own Game::Picture
  // #step/#finish_move bug already needed once.
  RClass* skill_menu = mrb_class_get_under(M, scene, "SkillMenu");
  mrb_define_method(M, skill_menu, "update", RPG2k__Scene__SkillMenu_update,
                    MRB_ARGS_NONE());
  mrb_define_method(M, skill_menu, "dispose", RPG2k__Scene__SkillMenu_dispose,
                    MRB_ARGS_NONE());

  mrb_define_private_method(M, skill_menu, "caster",
                            RPG2k__Scene__SkillMenu_caster, MRB_ARGS_NONE());
  mrb_define_private_method(M, skill_menu, "skills",
                            RPG2k__Scene__SkillMenu_skills, MRB_ARGS_NONE());
  mrb_define_private_method(M, skill_menu, "skill_name",
                            RPG2k__Scene__SkillMenu_skill_name,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, skill_menu, "update_skills",
                            RPG2k__Scene__SkillMenu_update_skills,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, skill_menu, "move_skill_cursor",
                            RPG2k__Scene__SkillMenu_move_skill_cursor,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, skill_menu, "skill_unavailable?",
                            RPG2k__Scene__SkillMenu_skill_unavailable_,
                            MRB_ARGS_REQ(2));
  mrb_define_private_method(M, skill_menu, "choose_skill",
                            RPG2k__Scene__SkillMenu_choose_skill,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, skill_menu, "enter_target_confirm",
                            RPG2k__Scene__SkillMenu_enter_target_confirm,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, skill_menu, "update_target",
                            RPG2k__Scene__SkillMenu_update_target,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, skill_menu, "apply_skill",
                            RPG2k__Scene__SkillMenu_apply_skill,
                            MRB_ARGS_REQ(2));
  mrb_define_private_method(M, skill_menu, "apply_switch_skill",
                            RPG2k__Scene__SkillMenu_apply_switch_skill,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, skill_menu, "leave_target",
                            RPG2k__Scene__SkillMenu_leave_target,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, skill_menu, "update_teleport_target",
                            RPG2k__Scene__SkillMenu_update_teleport_target,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, skill_menu, "move_teleport_cursor",
                            RPG2k__Scene__SkillMenu_move_teleport_cursor,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, skill_menu, "apply_escape_skill",
                            RPG2k__Scene__SkillMenu_apply_escape_skill,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, skill_menu, "apply_teleport_skill",
                            RPG2k__Scene__SkillMenu_apply_teleport_skill,
                            MRB_ARGS_REQ(2));
  mrb_define_private_method(M, skill_menu, "queue_teleport",
                            RPG2k__Scene__SkillMenu_queue_teleport,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, skill_menu, "enter_teleport_target",
                            RPG2k__Scene__SkillMenu_enter_teleport_target,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, skill_menu, "leave_teleport_target",
                            RPG2k__Scene__SkillMenu_leave_teleport_target,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, skill_menu, "left_panel_w",
                            RPG2k__Scene__SkillMenu_left_panel_w,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, skill_menu, "build_desc_window",
                            RPG2k__Scene__SkillMenu_build_desc_window,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, skill_menu, "refresh_desc",
                            RPG2k__Scene__SkillMenu_refresh_desc,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, skill_menu, "build_status_window",
                            RPG2k__Scene__SkillMenu_build_status_window,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, skill_menu, "draw_stat_pair",
                            RPG2k__Scene__SkillMenu_draw_stat_pair,
                            MRB_ARGS_REQ(6));
  mrb_define_private_method(M, skill_menu, "build_skill_window",
                            RPG2k__Scene__SkillMenu_build_skill_window,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, skill_menu, "build_mp_cost_window",
                            RPG2k__Scene__SkillMenu_build_mp_cost_window,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, skill_menu, "refresh_skill_cursor",
                            RPG2k__Scene__SkillMenu_refresh_skill_cursor,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, skill_menu, "total_rows",
                            RPG2k__Scene__SkillMenu_total_rows,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, skill_menu, "build_arrow_sprites",
                            RPG2k__Scene__SkillMenu_build_arrow_sprites,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, skill_menu, "build_arrow_sprite",
                            RPG2k__Scene__SkillMenu_build_arrow_sprite,
                            MRB_ARGS_REQ(2));
  mrb_define_private_method(M, skill_menu, "tick_arrows",
                            RPG2k__Scene__SkillMenu_tick_arrows,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, skill_menu, "refresh_arrows",
                            RPG2k__Scene__SkillMenu_refresh_arrows,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, skill_menu, "draw_target_face",
                            RPG2k__Scene__SkillMenu_draw_target_face,
                            MRB_ARGS_REQ(3));
  mrb_define_private_method(M, skill_menu, "refresh_target_cursor",
                            RPG2k__Scene__SkillMenu_refresh_target_cursor,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, skill_menu, "map_display_name",
                            RPG2k__Scene__SkillMenu_map_display_name,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, skill_menu, "teleport_col_w",
                            RPG2k__Scene__SkillMenu_teleport_col_w,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, skill_menu, "refresh_teleport_cursor",
                            RPG2k__Scene__SkillMenu_refresh_teleport_cursor,
                            MRB_ARGS_NONE());

  // RPG2k::Scene::DebugMenu (docs/adr/0139's own follow-up,
  // mruby-rpg2k/mrblib/scene/debug_menu.rb) -- the F9 debug menu itself:
  // Switch/Variable block-and-row editing (two genuine RPG_RT pages) plus
  // this codebase's own Map/Chipset/Animation tool pages. 32 of its 39
  // real bytecode-defined methods compile clean (33 as first shipped; down
  // to 32 as of a later round's own bc2cpp.rb compile_send fix, which
  // correctly stopped compiling #play_animation -- see its own
  // registration comment below), needing no new opcode work.
  //
  // #initialize (`super parent` as its own first statement, then two
  // purely-mandatory arguments) is the first shipped target whose own
  // #initialize is blocked by a real `super` call (OP_SUPER) rather than
  // non-mandatory arity, a Ruby block, or an exception clause -- a
  // genuine class-hierarchy method-dispatch feature (resolving and
  // invoking RPG2k::Scene::Base#initialize, not just self's own method
  // table), not a narrow single-opcode mechanical translation, so it
  // stays out of scope the same way every other compiled target's own
  // interpreted #initialize already does. bc2cpp's own
  // drop_unsafe_embeddings guard (the compiles_clean?-on-#initialize fix
  // from the Game::Party/RPG2k::Scene::MapViewer follow-up above)
  // correctly refuses to embed this class's own provably-typed ivars
  // (@mode/@focus: Symbol; @page/@block/@row/@anim_id/@map_id: Fixnum)
  // into an RData struct as a result -- confirmed directly against the
  // real generated output: RPG2k::Scene::DebugMenu does not appear in
  // bc2cpp's own "classes needing MRB_SET_INSTANCE_TT" diagnostic, so
  // every ivar access below still goes through the ordinary dynamic
  // iv_tbl, no MRB_SET_INSTANCE_TT call needed here.
  //
  // 5 more stay interpreted for the same established out-of-scope shapes,
  // confirmed against each one's own real generated #error marker rather
  // than guessed: #max_id and #refresh_switch_or_variable each use two
  // real Ruby blocks (`table.each { |id, _| ... }` /
  // `(0...SCREEN_BLOCKS).each do |b| ... end`-shaped, BLOCK/SENDB);
  // #digits_of uses one (`(n - 1).downto(0) do |i| ... end`); #editor_value
  // uses one (`@editor[:digits].reduce(0) { |a, d| ... }`); and
  // #open_map_viewer has a real `begin ... rescue StandardError => e
  // ... end` (RESCUE/RAISEIF/EXCEPT).
  //
  // Every method below is `private` in the real interpreted source
  // *except* the first 2 (#update, #dispose -- debug_menu.rb's own single
  // `private` sits right before #update_switch_or_variable, line 125, in
  // effect through the end of the class body -- confirmed directly
  // against the real source, not guessed from bc2cpp's own diagnostic) --
  // mrb_define_private_method for the other 31, the same real fix this
  // ADR's own Game::Picture #step/#finish_move bug already needed once.
  RClass* debug_menu = mrb_class_get_under(M, scene, "DebugMenu");
  mrb_define_method(M, debug_menu, "update", RPG2k__Scene__DebugMenu_update,
                    MRB_ARGS_NONE());
  mrb_define_method(M, debug_menu, "dispose", RPG2k__Scene__DebugMenu_dispose,
                    MRB_ARGS_NONE());

  mrb_define_private_method(M, debug_menu, "refresh",
                            RPG2k__Scene__DebugMenu_refresh, MRB_ARGS_NONE());
  mrb_define_private_method(M, debug_menu, "update_switch_or_variable",
                            RPG2k__Scene__DebugMenu_update_switch_or_variable,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, debug_menu, "update_block_focus",
                            RPG2k__Scene__DebugMenu_update_block_focus,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, debug_menu, "update_row_focus",
                            RPG2k__Scene__DebugMenu_update_row_focus,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, debug_menu, "update_chipset_page",
                            RPG2k__Scene__DebugMenu_update_chipset_page,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, debug_menu, "cycle_mode",
                            RPG2k__Scene__DebugMenu_cycle_mode,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, debug_menu, "max_page",
                            RPG2k__Scene__DebugMenu_max_page, MRB_ARGS_NONE());
  mrb_define_private_method(M, debug_menu, "move_block",
                            RPG2k__Scene__DebugMenu_move_block,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, debug_menu, "move_row",
                            RPG2k__Scene__DebugMenu_move_row, MRB_ARGS_REQ(1));
  mrb_define_private_method(M, debug_menu, "enter_row_focus",
                            RPG2k__Scene__DebugMenu_enter_row_focus,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, debug_menu, "turn_page",
                            RPG2k__Scene__DebugMenu_turn_page, MRB_ARGS_REQ(1));
  mrb_define_private_method(M, debug_menu, "current_id",
                            RPG2k__Scene__DebugMenu_current_id,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, debug_menu, "update_animation",
                            RPG2k__Scene__DebugMenu_update_animation,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, debug_menu, "update_map_page",
                            RPG2k__Scene__DebugMenu_update_map_page,
                            MRB_ARGS_NONE());
  // #play_animation is NOT registered here for the same reason -- its own
  // body calls `scene.anim_target(x, y, height: nil, index: nil,
  // flash_target: nil)`, whose own target (`RPG2k::Scene::Map#anim_target`)
  // declares all three as real MANDATORY keyword arguments (`height:`, no
  // default) -- silently dropping them the old way would not just pass a
  // wrong value, it would raise a real ArgumentError (missing keyword) at
  // runtime the moment this ran.
  mrb_define_private_method(M, debug_menu, "activate_row",
                            RPG2k__Scene__DebugMenu_activate_row,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, debug_menu, "row_name",
                            RPG2k__Scene__DebugMenu_row_name, MRB_ARGS_REQ(1));
  mrb_define_private_method(M, debug_menu, "row_value_text",
                            RPG2k__Scene__DebugMenu_row_value_text,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, debug_menu, "id_label",
                            RPG2k__Scene__DebugMenu_id_label, MRB_ARGS_REQ(1));
  mrb_define_private_method(M, debug_menu, "build_window",
                            RPG2k__Scene__DebugMenu_build_window,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, debug_menu, "refresh_map_page",
                            RPG2k__Scene__DebugMenu_refresh_map_page,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, debug_menu, "map_name",
                            RPG2k__Scene__DebugMenu_map_name, MRB_ARGS_REQ(1));
  mrb_define_private_method(M, debug_menu, "refresh_chipset_page",
                            RPG2k__Scene__DebugMenu_refresh_chipset_page,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, debug_menu, "refresh_animation_page",
                            RPG2k__Scene__DebugMenu_refresh_animation_page,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, debug_menu, "animation_name",
                            RPG2k__Scene__DebugMenu_animation_name,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, debug_menu, "editor_digits",
                            RPG2k__Scene__DebugMenu_editor_digits,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, debug_menu, "open_editor",
                            RPG2k__Scene__DebugMenu_open_editor,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, debug_menu, "build_editor_window",
                            RPG2k__Scene__DebugMenu_build_editor_window,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, debug_menu, "refresh_editor",
                            RPG2k__Scene__DebugMenu_refresh_editor,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, debug_menu, "update_editor",
                            RPG2k__Scene__DebugMenu_update_editor,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, debug_menu, "close_editor",
                            RPG2k__Scene__DebugMenu_close_editor,
                            MRB_ARGS_NONE());

  // RPG2k::Scene::EquipMenu (docs/adr/0139's own follow-up, mruby-rpg2k/
  // mrblib/scene/equip_menu.rb) -- the field equip screen. 29 of its own 36
  // real bytecode-defined methods compile clean, needing no new opcode work
  // (same shape as the Game::Battle/RPG2k::Scene::ItemMenu round above).
  // #initialize (`actor_index = 0`, a non-mandatory argument) and 6 other
  // real methods (#draw_stat_row/#build_slot_window/#build_cand_window's
  // own each_with_index, #item_stat_sum/#equip_delta's own reduce,
  // #draw_arrow_fallback's own ARROW_H.times -- all a genuine Ruby block,
  // BLOCK/SENDB, confirmed against each one's own generated #error line)
  // stay uncompiled and never registered here, so they keep running
  // mruby-rpg2k's own interpreted mrblib body unchanged, the same
  // documented fallback every other unsupported method in this codebase
  // already gets. Because #initialize itself never compiles,
  // drop_unsafe_embeddings correctly refuses to embed any of EquipMenu's
  // own provably-Fixnum/Symbol ivars (@actor_index/@slot_index/
  // @cand_index/@cand_top/@arrow_anim/@mode) into a struct -- same shape as
  // Game::Picture/RPG2k::Window/Game::Actor/Game::Party/
  // RPG2k::Scene::MapViewer/Game::Battle/RPG2k::Scene::ItemMenu above, no
  // MRB_SET_INSTANCE_TT call needed here. Reuses the `scene` RClass* the
  // RPG2k::Scene::MapViewer/ItemMenu blocks above already looked up -- all
  // three live under the same RPG2k::Scene module.
  RClass* equip_menu = mrb_class_get_under(M, scene, "EquipMenu");
  mrb_define_method(M, equip_menu, "update", RPG2k__Scene__EquipMenu_update,
                    MRB_ARGS_NONE());
  mrb_define_method(M, equip_menu, "dispose", RPG2k__Scene__EquipMenu_dispose,
                    MRB_ARGS_NONE());

  // Everything from here down is `private` in the real interpreted source
  // (mruby-rpg2k/mrblib/scene/equip_menu.rb line 195, in effect through the
  // end of the class body).
  mrb_define_private_method(M, equip_menu, "tick_arrows",
                            RPG2k__Scene__EquipMenu_tick_arrows,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, equip_menu, "refresh_arrows",
                            RPG2k__Scene__EquipMenu_refresh_arrows,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, equip_menu, "build_arrow_sprites",
                            RPG2k__Scene__EquipMenu_build_arrow_sprites,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, equip_menu, "build_arrow_sprite",
                            RPG2k__Scene__EquipMenu_build_arrow_sprite,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, equip_menu, "item_name",
                            RPG2k__Scene__EquipMenu_item_name, MRB_ARGS_REQ(1));
  mrb_define_private_method(M, equip_menu, "warn_missing_item",
                            RPG2k__Scene__EquipMenu_warn_missing_item,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, equip_menu, "build_desc_window",
                            RPG2k__Scene__EquipMenu_build_desc_window,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, equip_menu, "refresh_desc",
                            RPG2k__Scene__EquipMenu_refresh_desc,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, equip_menu, "update_items",
                            RPG2k__Scene__EquipMenu_update_items,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, equip_menu, "actor",
                            RPG2k__Scene__EquipMenu_actor, MRB_ARGS_NONE());
  mrb_define_private_method(M, equip_menu, "update_slots",
                            RPG2k__Scene__EquipMenu_update_slots,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, equip_menu, "move_slot_cursor",
                            RPG2k__Scene__EquipMenu_move_slot_cursor,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, equip_menu, "candidates",
                            RPG2k__Scene__EquipMenu_candidates,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, equip_menu, "move_cand_cursor",
                            RPG2k__Scene__EquipMenu_move_cand_cursor,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, equip_menu, "scroll_cand_list_to_cursor",
                            RPG2k__Scene__EquipMenu_scroll_cand_list_to_cursor,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, equip_menu, "cand_row_count",
                            RPG2k__Scene__EquipMenu_cand_row_count,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, equip_menu, "apply_choice",
                            RPG2k__Scene__EquipMenu_apply_choice,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, equip_menu, "leave_items",
                            RPG2k__Scene__EquipMenu_leave_items,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, equip_menu, "rebuild_for_actor",
                            RPG2k__Scene__EquipMenu_rebuild_for_actor,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, equip_menu, "build_stats_window",
                            RPG2k__Scene__EquipMenu_build_stats_window,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, equip_menu, "refresh_slot_cursor",
                            RPG2k__Scene__EquipMenu_refresh_slot_cursor,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, equip_menu, "item_stat",
                            RPG2k__Scene__EquipMenu_item_stat, MRB_ARGS_REQ(2));
  mrb_define_private_method(M, equip_menu, "other_hand_item",
                            RPG2k__Scene__EquipMenu_other_hand_item,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, equip_menu, "stat_field_delta",
                            RPG2k__Scene__EquipMenu_stat_field_delta,
                            MRB_ARGS_REQ(2));
  mrb_define_private_method(M, equip_menu, "cand_col_w",
                            RPG2k__Scene__EquipMenu_cand_col_w,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, equip_menu, "cand_col_x",
                            RPG2k__Scene__EquipMenu_cand_col_x,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, equip_menu, "refresh_cand_cursor",
                            RPG2k__Scene__EquipMenu_refresh_cand_cursor,
                            MRB_ARGS_NONE());

  // RPG2k::Scene::Menu (mruby-rpg2k/mrblib/scene/menu.rb) -- the field
  // main menu, 28 of its own 35 real bytecode-defined methods (see this
  // file's own top comment for the full gap breakdown). 4 public methods
  // (#dispose/#suspend/#resume/#update, all defined before the source's
  // own `private` line) are registered first, then a single bare
  // `private` (menu.rb line 215, in effect through the end of the class
  // body, no retroactive `public` reopen anywhere after it -- confirmed
  // directly against the real source, not guessed from bc2cpp's own
  // diagnostic) makes the other 24 registered below private too --
  // mrb_define_private_method for all of them, the same real fix this
  // ADR's own Game::Picture #step/#finish_move bug already needed once.
  // #initialize never compiles (a real SUPER call), so
  // drop_unsafe_embeddings correctly refuses to embed any of Menu's own
  // provably-typed ivars into a struct -- confirmed Menu does not appear
  // in bc2cpp's own "classes needing MRB_SET_INSTANCE_TT" diagnostic, no
  // MRB_SET_INSTANCE_TT call needed here. Reuses the `scene` RClass* the
  // RPG2k::Scene::MapViewer/ItemMenu blocks above already looked up.
  RClass* menu = mrb_class_get_under(M, scene, "Menu");
  mrb_define_method(M, menu, "dispose", RPG2k__Scene__Menu_dispose,
                    MRB_ARGS_NONE());
  mrb_define_method(M, menu, "suspend", RPG2k__Scene__Menu_suspend,
                    MRB_ARGS_NONE());
  mrb_define_method(M, menu, "resume", RPG2k__Scene__Menu_resume,
                    MRB_ARGS_NONE());
  mrb_define_method(M, menu, "update", RPG2k__Scene__Menu_update,
                    MRB_ARGS_NONE());

  // Everything from here down is `private` in the real interpreted
  // source (mruby-rpg2k/mrblib/scene/menu.rb line 215, in effect through
  // the end of the class body).
  mrb_define_private_method(M, menu, "update_command",
                            RPG2k__Scene__Menu_update_command, MRB_ARGS_NONE());
  mrb_define_private_method(M, menu, "update_actor_selection",
                            RPG2k__Scene__Menu_update_actor_selection,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, menu, "confirm_actor_selection",
                            RPG2k__Scene__Menu_confirm_actor_selection,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, menu, "leave_actor_selection",
                            RPG2k__Scene__Menu_leave_actor_selection,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, menu, "wait_term_for",
                            RPG2k__Scene__Menu_wait_term_for, MRB_ARGS_REQ(2));
  mrb_define_private_method(M, menu, "wait_label",
                            RPG2k__Scene__Menu_wait_label, MRB_ARGS_NONE());
  mrb_define_private_method(M, menu, "build_gold_window",
                            RPG2k__Scene__Menu_build_gold_window,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, menu, "draw_gold_window",
                            RPG2k__Scene__Menu_draw_gold_window,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, menu, "refresh_cursor",
                            RPG2k__Scene__Menu_refresh_cursor, MRB_ARGS_NONE());
  mrb_define_private_method(M, menu, "draw_status_stat",
                            RPG2k__Scene__Menu_draw_status_stat,
                            MRB_ARGS_REQ(6));
  mrb_define_private_method(M, menu, "draw_status_exp",
                            RPG2k__Scene__Menu_draw_status_exp,
                            MRB_ARGS_REQ(3));
  mrb_define_private_method(M, menu, "draw_actor_face",
                            RPG2k__Scene__Menu_draw_actor_face,
                            MRB_ARGS_REQ(4));
  mrb_define_private_method(M, menu, "redraw_command_labels",
                            RPG2k__Scene__Menu_redraw_command_labels,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, menu, "command_disabled?",
                            RPG2k__Scene__Menu_command_disabled_,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, menu, "refresh_status_cursor",
                            RPG2k__Scene__Menu_refresh_status_cursor,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, menu, "enter_actor_selection",
                            RPG2k__Scene__Menu_enter_actor_selection,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, menu, "select_command",
                            RPG2k__Scene__Menu_select_command, MRB_ARGS_NONE());
  mrb_define_private_method(M, menu, "open_end_game_confirm",
                            RPG2k__Scene__Menu_open_end_game_confirm,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, menu, "refresh_end_game_cursor",
                            RPG2k__Scene__Menu_refresh_end_game_cursor,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, menu, "update_end_game_confirm",
                            RPG2k__Scene__Menu_update_end_game_confirm,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, menu, "close_end_game_confirm",
                            RPG2k__Scene__Menu_close_end_game_confirm,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, menu, "drive_message",
                            RPG2k__Scene__Menu_drive_message, MRB_ARGS_NONE());
  mrb_define_private_method(M, menu, "show_message",
                            RPG2k__Scene__Menu_show_message, MRB_ARGS_REQ(1));
  mrb_define_private_method(M, menu, "close_message",
                            RPG2k__Scene__Menu_close_message, MRB_ARGS_NONE());

  // Game::State (mruby-rpg2k/mrblib/game.rb, reopened by mruby-rpg2k/mrblib/
  // game/lsd_io.rb) -- see this file's own top comment for the real gap
  // breakdown and the embedding this class's own compiling #initialize
  // unlocks. No bare `private` anywhere in either source file (confirmed
  // directly, not guessed from bc2cpp's own diagnostic), so every method
  // below is `mrb_define_method` except #initialize itself, which mruby's
  // own src/class.c forces private unconditionally regardless of source,
  // the same always-private special case as every other shipped target's
  // own #initialize.
  RClass* state = mrb_class_get_under(M, game, "State");
  MRB_SET_INSTANCE_TT(state, MRB_TT_DATA);

  mrb_define_private_method(M, state, "initialize", Game__State_initialize,
                            MRB_ARGS_REQ(4));
  mrb_define_method(M, state, "map_id=", Game__State_map_id_, MRB_ARGS_REQ(1));
  mrb_define_method(M, state, "set_parallax", Game__State_set_parallax,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, state, "clear_parallax", Game__State_clear_parallax,
                    MRB_ARGS_NONE());
  mrb_define_method(M, state, "vehicle", Game__State_vehicle, MRB_ARGS_REQ(1));
  mrb_define_method(M, state, "boarded?", Game__State_boarded_,
                    MRB_ARGS_NONE());
  mrb_define_method(M, state, "walk_step", Game__State_walk_step,
                    MRB_ARGS_NONE());
  mrb_define_method(M, state, "show_picture", Game__State_show_picture,
                    MRB_ARGS_REQ(2));
  mrb_define_method(M, state, "erase_picture", Game__State_erase_picture,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, state, "erase_all_pictures",
                    Game__State_erase_all_pictures, MRB_ARGS_NONE());
  mrb_define_method(M, state, "timer_seconds", Game__State_timer_seconds,
                    MRB_ARGS_NONE());
  mrb_define_method(M, state, "timer_display_text",
                    Game__State_timer_display_text, MRB_ARGS_NONE());
  mrb_define_method(M, state, "timer2_seconds", Game__State_timer2_seconds,
                    MRB_ARGS_NONE());
  mrb_define_method(M, state, "timer_frames", Game__State_timer_frames,
                    MRB_ARGS_NONE());
  mrb_define_method(M, state, "timer_frames=", Game__State_timer_frames_,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, state, "timer_running", Game__State_timer_running,
                    MRB_ARGS_NONE());
  mrb_define_method(M, state, "timer_running=", Game__State_timer_running_,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, state, "timer_visible", Game__State_timer_visible,
                    MRB_ARGS_NONE());
  mrb_define_method(M, state, "timer_visible=", Game__State_timer_visible_,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, state, "set_screen_transition",
                    Game__State_set_screen_transition, MRB_ARGS_REQ(2));
  mrb_define_method(M, state, "set_system_graphic",
                    Game__State_set_system_graphic, MRB_ARGS_REQ(2));
  mrb_define_method(M, state, "bgm_chunk", Game__State_bgm_chunk,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, state, "se_chunk", Game__State_se_chunk,
                    MRB_ARGS_REQ(1));

  // RPG2k::Scene::StatusMenu (mruby-rpg2k/mrblib/scene/status_menu.rb) --
  // the field per-character status detail screen (stats, equipped gear,
  // EXP progress for one selected party member, drawn across five
  // windows: actor panel, gold, HP/MP/EXP gauges, parameters, equipment).
  // 13 of its own 21 real bytecode-defined methods compile clean, needing
  // no new opcode work at all: the opcode set nine rounds of this ADR
  // have already built up already covers every real shape this class's
  // own method bodies use.
  //
  // #initialize (`actor_index = 0`, one optional argument, plus a
  // `super parent` call) stays interpreted, the same non-mandatory-arity
  // gap as Game::Picture/RPG2k::Window/Game::Actor/Game::Party/
  // RPG2k::Scene::MapViewer/RPG2k::Scene::SkillMenu's own #initialize
  // above -- so, like those six, bc2cpp's own drop_unsafe_embeddings guard
  // refuses to embed this class's own one real provably-Fixnum ivar
  // (@actor_index) into an RData struct: every ivar access below still
  // goes through the ordinary dynamic iv_tbl, no MRB_SET_INSTANCE_TT call
  // needed here -- confirmed directly against the real generated output,
  // the same way as every other non-embedding target's own top-of-file
  // comment already documents.
  //
  // The 7 methods that stay interpreted are genuinely out of this
  // prototype's scope, not a missing opcode -- confirmed against the real
  // generated `#error` markers, not guessed: #update and #dispose each
  // call `windows.each { |w| ... }` (a real Ruby block, BLOCK/SENDB);
  // #draw_actor_panel, #draw_params and #draw_equipment each use
  // `.each_with_index do |...| ... end` (also BLOCK/SENDB);
  // #draw_value_row has one optional argument (`can_knockout = nil`, the
  // same non-mandatory-arity gap as #initialize); and #load_face_bitmap
  // has a real `rescue StandardError => e` clause (RESCUE/RAISEIF/
  // EXCEPT), the same established shape SkillMenu's own #load_face_bitmap
  // already documents above.
  //
  // Every method below is `private` in the real interpreted source --
  // status_menu.rb's own single `private` sits right before #windows,
  // line 162, in effect through the end of the class body (confirmed
  // directly against the real source, not guessed from bc2cpp's own
  // diagnostic); #initialize/#dispose/#update, the three methods above
  // that `private` line, all stay interpreted anyway (see above), so
  // mrb_define_private_method is the only registration this class's own
  // block below ever needs -- unlike Picture's own #step/#finish_move
  // fix, there is no plain mrb_define_method call here to get wrong.
  RClass* status_menu = mrb_class_get_under(M, scene, "StatusMenu");
  mrb_define_private_method(M, status_menu, "windows",
                            RPG2k__Scene__StatusMenu_windows, MRB_ARGS_NONE());
  mrb_define_private_method(M, status_menu, "item_name",
                            RPG2k__Scene__StatusMenu_item_name,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, status_menu, "warn_missing_item",
                            RPG2k__Scene__StatusMenu_warn_missing_item,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, status_menu, "build_windows",
                            RPG2k__Scene__StatusMenu_build_windows,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, status_menu, "new_window",
                            RPG2k__Scene__StatusMenu_new_window,
                            MRB_ARGS_REQ(4));
  mrb_define_private_method(M, status_menu, "new_contents",
                            RPG2k__Scene__StatusMenu_new_contents,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, status_menu, "refresh",
                            RPG2k__Scene__StatusMenu_refresh, MRB_ARGS_NONE());
  mrb_define_private_method(M, status_menu, "draw_actor_face",
                            RPG2k__Scene__StatusMenu_draw_actor_face,
                            MRB_ARGS_REQ(2));
  mrb_define_private_method(M, status_menu, "draw_gold",
                            RPG2k__Scene__StatusMenu_draw_gold,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, status_menu, "draw_gauges",
                            RPG2k__Scene__StatusMenu_draw_gauges,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, status_menu, "slot_labels",
                            RPG2k__Scene__StatusMenu_slot_labels,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, status_menu, "rpg2003_party?",
                            RPG2k__Scene__StatusMenu_rpg2003_party_,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, status_menu, "draw_battle_row",
                            RPG2k__Scene__StatusMenu_draw_battle_row,
                            MRB_ARGS_REQ(2));

  // Game::MoveRoute (mruby-rpg2k/mrblib/game.rb) -- the RPG2000 "Set Move
  // Route" event-command engine. 18 of its own 19 real bytecode-defined
  // methods (see this file's own top comment for the full gap breakdown:
  // #initialize's own keyword arguments, and the two singleton `def self.`
  // methods bc2cpp's build_registry never sees at all). 6 public methods
  // (#done?/#empty?/#repeat?/#skippable?/#resume_at/#step) are registered
  // first -- all defined before the source's own `private` line
  // (mruby-rpg2k/mrblib/game.rb line 6626, in effect through the end of the
  // class body, no retroactive `public` reopen anywhere after it) -- then
  // the 12 methods below it are all mrb_define_private_method. #initialize
  // never compiles, so drop_unsafe_embeddings correctly refuses to embed
  // @index (the class's one provably-Fixnum embed candidate) -- confirmed
  // Game::MoveRoute does not appear in bc2cpp's own "classes needing
  // MRB_SET_INSTANCE_TT" diagnostic, no MRB_SET_INSTANCE_TT call needed
  // here.
  RClass* move_route = mrb_class_get_under(M, game, "MoveRoute");
  mrb_define_method(M, move_route, "done?", Game__MoveRoute_done_,
                    MRB_ARGS_NONE());
  mrb_define_method(M, move_route, "empty?", Game__MoveRoute_empty_,
                    MRB_ARGS_NONE());
  mrb_define_method(M, move_route, "repeat?", Game__MoveRoute_repeat_,
                    MRB_ARGS_NONE());
  mrb_define_method(M, move_route, "skippable?", Game__MoveRoute_skippable_,
                    MRB_ARGS_NONE());
  mrb_define_method(M, move_route, "resume_at", Game__MoveRoute_resume_at,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, move_route, "step", Game__MoveRoute_step,
                    MRB_ARGS_REQ(2));

  // Everything from here down is `private` in the real interpreted source
  // (mruby-rpg2k/mrblib/game.rb line 6626, in effect through the end of the
  // class body).
  mrb_define_private_method(M, move_route, "advance_cursor",
                            Game__MoveRoute_advance_cursor, MRB_ARGS_NONE());
  mrb_define_private_method(M, move_route, "execute", Game__MoveRoute_execute,
                            MRB_ARGS_REQ(3));
  mrb_define_private_method(M, move_route, "do_move", Game__MoveRoute_do_move,
                            MRB_ARGS_REQ(3));
  mrb_define_private_method(M, move_route, "do_jump", Game__MoveRoute_do_jump,
                            MRB_ARGS_REQ(2));
  mrb_define_private_method(M, move_route, "land_jump",
                            Game__MoveRoute_land_jump, MRB_ARGS_REQ(5));
  mrb_define_private_method(M, move_route, "jump_move_direction",
                            Game__MoveRoute_jump_move_direction,
                            MRB_ARGS_REQ(4));
  mrb_define_private_method(M, move_route, "jump_delta",
                            Game__MoveRoute_jump_delta, MRB_ARGS_REQ(2));
  mrb_define_private_method(M, move_route, "jump_face_direction",
                            Game__MoveRoute_jump_face_direction,
                            MRB_ARGS_REQ(4));
  mrb_define_private_method(M, move_route, "do_diagonal",
                            Game__MoveRoute_do_diagonal, MRB_ARGS_REQ(3));
  mrb_define_private_method(M, move_route, "do_diagonal_dir",
                            Game__MoveRoute_do_diagonal_dir, MRB_ARGS_REQ(4));
  mrb_define_private_method(M, move_route, "toward_hero",
                            Game__MoveRoute_toward_hero, MRB_ARGS_REQ(2));
  mrb_define_private_method(M, move_route, "away_hero",
                            Game__MoveRoute_away_hero, MRB_ARGS_REQ(2));

  // RPG2k::Scene::ChipsetEditor (mruby-rpg2k/mrblib/scene/
  // chipset_editor.rb) -- the F9 debug menu's Chipset (passability) page.
  // 2 public methods (#update/#dispose, both defined before the source's
  // own `private` line) are registered first, then a single bare
  // `private` (chipset_editor.rb line 98, in effect through the end of
  // the class body, no retroactive `public` reopen anywhere after it --
  // confirmed directly against the real source) makes the other 15
  // registered below private too. #initialize (a keyword argument plus a
  // real `super` call), #save_to_disk (a real `rescue StandardError`
  // clause), and #draw_grid (a genuine Ruby block) never compile, so they
  // keep running mruby-rpg2k's own interpreted mrblib body unchanged, the
  // same documented fallback every other unsupported method in this
  // codebase already gets; drop_unsafe_embeddings correctly refuses to
  // embed any of ChipsetEditor's own provably-typed ivars as a result, no
  // MRB_SET_INSTANCE_TT call needed here (see this file's own top
  // comment for the full breakdown). Reuses the `scene` RClass* every
  // other RPG2k::Scene block above already looked up.
  RClass* chipset_editor = mrb_class_get_under(M, scene, "ChipsetEditor");
  mrb_define_method(M, chipset_editor, "update",
                    RPG2k__Scene__ChipsetEditor_update, MRB_ARGS_NONE());
  mrb_define_method(M, chipset_editor, "dispose",
                    RPG2k__Scene__ChipsetEditor_dispose, MRB_ARGS_NONE());

  // Everything from here down is `private` in the real interpreted
  // source (mruby-rpg2k/mrblib/scene/chipset_editor.rb line 98, in effect
  // through the end of the class body).
  mrb_define_private_method(M, chipset_editor, "close",
                            RPG2k__Scene__ChipsetEditor_close, MRB_ARGS_NONE());
  mrb_define_private_method(M, chipset_editor, "switch_tab",
                            RPG2k__Scene__ChipsetEditor_switch_tab,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, chipset_editor, "cell_count",
                            RPG2k__Scene__ChipsetEditor_cell_count,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, chipset_editor, "rows",
                            RPG2k__Scene__ChipsetEditor_rows, MRB_ARGS_NONE());
  mrb_define_private_method(M, chipset_editor, "move_cursor",
                            RPG2k__Scene__ChipsetEditor_move_cursor,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, chipset_editor, "current_bytes",
                            RPG2k__Scene__ChipsetEditor_current_bytes,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, chipset_editor, "toggle_passable",
                            RPG2k__Scene__ChipsetEditor_toggle_passable,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, chipset_editor, "toggled_byte",
                            RPG2k__Scene__ChipsetEditor_toggled_byte,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, chipset_editor, "refresh",
                            RPG2k__Scene__ChipsetEditor_refresh,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, chipset_editor, "draw_header",
                            RPG2k__Scene__ChipsetEditor_draw_header,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, chipset_editor, "cell_word",
                            RPG2k__Scene__ChipsetEditor_cell_word,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, chipset_editor, "draw_footer",
                            RPG2k__Scene__ChipsetEditor_draw_footer,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, chipset_editor, "cell_color",
                            RPG2k__Scene__ChipsetEditor_cell_color,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, chipset_editor, "cell_color_for",
                            RPG2k__Scene__ChipsetEditor_cell_color_for,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, chipset_editor, "draw_cursor",
                            RPG2k__Scene__ChipsetEditor_draw_cursor,
                            MRB_ARGS_NONE());

  // RPG2k::Scene::Base (mruby-rpg2k/mrblib/scene/base.rb, reopened by
  // mruby-rpg2k/mrblib/scene/battle_support.rb) -- the common superclass
  // every other RPG2k::Scene::* class in this codebase inherits from
  // (windowskin loading, the field-menu backdrop, scrolling-list arrow/
  // blink helpers, system-text/state-colour drawing, system-SFX playback,
  // UTF-8-vs-byte string walking). 17 of its own 29 real bytecode-defined
  // methods compile clean, needing no new opcode work at all: the opcode
  // set nine rounds of this ADR have already built up already covers every
  // real shape this class's own method bodies use.
  //
  // #initialize (`def initialize parent`) compiles clean -- pure
  // mandatory arity, and (being the root of the RPG2k::Scene hierarchy)
  // no `super` call to block it, unlike every subclass built on top of
  // it. Its own 3 ivars (@parent, @db, @map_tree) are all opaque object
  // references (never a provably-Fixnum value on any real construction
  // site), so bc2cpp's own whole-program embedding diagnostic does not
  // propose `MRB_SET_INSTANCE_TT` here at all -- confirmed directly
  // against the real diagnostic output, not assumed: RPG2k::Scene::Base
  // does not appear in its "classes needing MRB_SET_INSTANCE_TT" list,
  // so this stays a plain, non-embedding registration exactly like
  // RPG2k::Scene::StatusMenu's own block above.
  //
  // The 12 methods that stay interpreted are genuinely out of this
  // prototype's scope, not a missing opcode -- confirmed against the
  // real generated `#error` markers, not guessed: #make_windowskin,
  // #play_system_se, #screen_width and #screen_height each have a real
  // `rescue` clause (RESCUE/RAISEIF/EXCEPT); #build_list_arrow_sprite,
  // #draw_system_text and #draw_actor_state each have a non-mandatory
  // argument (a trailing `= ...` default); #draw_list_arrow_fallback,
  // #clip_text_to_width, #wrap_text_to_width and #draw_wrapped_hint each
  // call a real Ruby block (`LIST_ARROW_H.times do ... end`/
  // `text.each_char do ... end`/`text.split(' ').each do ... end`/
  // `....each_with_index do ... end`, all BLOCK/SENDB); and
  // #play_animation_se combines a block (`anim.timings.each do |_id, t|
  // ... end`) with its own `rescue StandardError` clause, the same
  // combined shape Game::State's own #seed_screen_transitions/
  // #seed_vehicle_positions already established.
  //
  // No bare `private` anywhere in either source file (confirmed directly,
  // not guessed from bc2cpp's own diagnostic), so every method below is
  // `mrb_define_method` except #initialize itself, which mruby's own
  // src/class.c forces private unconditionally regardless of source, the
  // same always-private special case as every other shipped target's own
  // #initialize.
  RClass* base = mrb_class_get_under(M, scene, "Base");
  mrb_define_private_method(M, base, "initialize",
                            RPG2k__Scene__Base_initialize, MRB_ARGS_REQ(1));
  mrb_define_method(M, base, "update", RPG2k__Scene__Base_update,
                    MRB_ARGS_NONE());
  mrb_define_method(M, base, "dispose", RPG2k__Scene__Base_dispose,
                    MRB_ARGS_NONE());
  mrb_define_method(M, base, "build_field_background",
                    RPG2k__Scene__Base_build_field_background, MRB_ARGS_REQ(1));
  mrb_define_method(M, base, "utf8_chars", RPG2k__Scene__Base_utf8_chars,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, base, "utf8_chars_bytewise",
                    RPG2k__Scene__Base_utf8_chars_bytewise, MRB_ARGS_REQ(1));
  mrb_define_method(M, base, "state_table", RPG2k__Scene__Base_state_table,
                    MRB_ARGS_NONE());
  mrb_define_method(M, base, "state_display", RPG2k__Scene__Base_state_display,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, base, "value_font_color",
                    RPG2k__Scene__Base_value_font_color, MRB_ARGS_REQ(3));
  mrb_define_method(M, base, "draw_stat_segment",
                    RPG2k__Scene__Base_draw_stat_segment, MRB_ARGS_REQ(10));
  mrb_define_method(M, base, "normal_status_term",
                    RPG2k__Scene__Base_normal_status_term, MRB_ARGS_NONE());
  mrb_define_method(M, base, "term", RPG2k__Scene__Base_term, MRB_ARGS_REQ(1));
  mrb_define_method(M, base, "system_se", RPG2k__Scene__Base_system_se,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, base, "db_system_se", RPG2k__Scene__Base_db_system_se,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, base, "advance_list_arrow_anim",
                    RPG2k__Scene__Base_advance_list_arrow_anim,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, base, "list_arrow_blink_on?",
                    RPG2k__Scene__Base_list_arrow_blink_on_, MRB_ARGS_REQ(1));
  mrb_define_method(M, base, "sticky_list_top",
                    RPG2k__Scene__Base_sticky_list_top, MRB_ARGS_REQ(4));

  // Game::Character (mruby-rpg2k/mrblib/game.rb) -- see this file's own
  // top comment for the real gap breakdown (#initialize/#front_tile, both
  // non-mandatory arity) and why no MRB_SET_INSTANCE_TT call belongs
  // here. No bare `private` anywhere in the real source (confirmed
  // directly, not guessed from bc2cpp's own diagnostic), so every method
  // below is `mrb_define_method`.
  RClass* character = mrb_class_get_under(M, game, "Character");
  mrb_define_method(M, character, "x=", Game__Character_x_, MRB_ARGS_REQ(1));
  mrb_define_method(M, character, "y=", Game__Character_y_, MRB_ARGS_REQ(1));
  mrb_define_method(M, character, "set_graphic", Game__Character_set_graphic,
                    MRB_ARGS_REQ(2));
  mrb_define_method(M, character, "face", Game__Character_face,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, character, "face!", Game__Character_face_,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, character, "move", Game__Character_move,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, character, "jump", Game__Character_jump,
                    MRB_ARGS_REQ(2));
  mrb_define_method(M, character, "diagonal_facing",
                    Game__Character_diagonal_facing, MRB_ARGS_REQ(2));
  mrb_define_method(M, character, "move_diagonal",
                    Game__Character_move_diagonal, MRB_ARGS_REQ(2));
  mrb_define_method(M, character, "turn_right", Game__Character_turn_right,
                    MRB_ARGS_NONE());
  mrb_define_method(M, character, "turn_left", Game__Character_turn_left,
                    MRB_ARGS_NONE());
  mrb_define_method(M, character, "turn_around", Game__Character_turn_around,
                    MRB_ARGS_NONE());
  mrb_define_method(M, character, "direction_toward",
                    Game__Character_direction_toward, MRB_ARGS_REQ(2));
  mrb_define_method(M, character, "direction_away",
                    Game__Character_direction_away, MRB_ARGS_REQ(2));

  // RPG2k::Scene::SaveLoad (mruby-rpg2k/mrblib/scene/save_load.rb) -- see
  // this file's own top comment for the real gap breakdown (#initialize's
  // own SUPER/BLOCK, plus each of the 9 other interpreted methods' own
  // real BLOCK/SENDB/RESCUE/RAISEIF/EXCEPT) and why no
  // MRB_SET_INSTANCE_TT call belongs here. Every method below sits after
  // a bare `private` in the real source (confirmed directly, not guessed
  // from bc2cpp's own diagnostic), so all 12 use
  // mrb_define_private_method.
  RClass* save_load = mrb_class_get_under(M, scene, "SaveLoad");
  mrb_define_private_method(M, save_load, "tick_arrows",
                            RPG2k__Scene__SaveLoad_tick_arrows,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, save_load, "refresh_arrows",
                            RPG2k__Scene__SaveLoad_refresh_arrows,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, save_load, "build_arrow_sprites",
                            RPG2k__Scene__SaveLoad_build_arrow_sprites,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, save_load, "build_arrow_sprite",
                            RPG2k__Scene__SaveLoad_build_arrow_sprite,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, save_load, "move_selection",
                            RPG2k__Scene__SaveLoad_move_selection,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, save_load, "confirm_selection",
                            RPG2k__Scene__SaveLoad_confirm_selection,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, save_load, "build_header_window",
                            RPG2k__Scene__SaveLoad_build_header_window,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, save_load, "draw_slot_label",
                            RPG2k__Scene__SaveLoad_draw_slot_label,
                            MRB_ARGS_REQ(3));
  mrb_define_private_method(M, save_load, "draw_slot_box",
                            RPG2k__Scene__SaveLoad_draw_slot_box,
                            MRB_ARGS_REQ(3));
  mrb_define_private_method(M, save_load, "draw_level_hp",
                            RPG2k__Scene__SaveLoad_draw_level_hp,
                            MRB_ARGS_REQ(5));
  mrb_define_private_method(M, save_load, "fixed_width_term",
                            RPG2k__Scene__SaveLoad_fixed_width_term,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, save_load, "build_face_cell",
                            RPG2k__Scene__SaveLoad_build_face_cell,
                            MRB_ARGS_REQ(2));

  // RPG2k::Scene::Order (mruby-rpg2k/mrblib/scene/order.rb) -- see this
  // file's own top comment for the real gap breakdown (#initialize's own
  // SUPER, plus 3 real BLOCK/SENDB gaps) and why no MRB_SET_INSTANCE_TT
  // call belongs here. 2 public methods (#update/#dispose, both defined
  // before the source's own `private` line) are registered first, then a
  // single bare `private` (order.rb line 107, in effect through the end
  // of the class body, no retroactive `public` reopen anywhere after it)
  // makes the other 10 registered below private too.
  RClass* order = mrb_class_get_under(M, scene, "Order");
  mrb_define_method(M, order, "update", RPG2k__Scene__Order_update,
                    MRB_ARGS_NONE());
  mrb_define_method(M, order, "dispose", RPG2k__Scene__Order_dispose,
                    MRB_ARGS_NONE());
  mrb_define_private_method(M, order, "update_left",
                            RPG2k__Scene__Order_update_left, MRB_ARGS_NONE());
  mrb_define_private_method(M, order, "move_cursor",
                            RPG2k__Scene__Order_move_cursor, MRB_ARGS_REQ(1));
  mrb_define_private_method(M, order, "pick_current",
                            RPG2k__Scene__Order_pick_current, MRB_ARGS_NONE());
  mrb_define_private_method(M, order, "undo_last_pick",
                            RPG2k__Scene__Order_undo_last_pick,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, order, "enter_confirm",
                            RPG2k__Scene__Order_enter_confirm, MRB_ARGS_NONE());
  mrb_define_private_method(M, order, "update_confirm",
                            RPG2k__Scene__Order_update_confirm,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, order, "confirm_order",
                            RPG2k__Scene__Order_confirm_order, MRB_ARGS_NONE());
  mrb_define_private_method(M, order, "redo_picks",
                            RPG2k__Scene__Order_redo_picks, MRB_ARGS_NONE());
  mrb_define_private_method(M, order, "refresh_left_cursor",
                            RPG2k__Scene__Order_refresh_left_cursor,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, order, "refresh_confirm_cursor",
                            RPG2k__Scene__Order_refresh_confirm_cursor,
                            MRB_ARGS_NONE());

  // Game::Shop (mruby-rpg2k/mrblib/game.rb) -- see this file's own top
  // comment for the real gap breakdown (#initialize's own genuine Ruby
  // block; #buy/#sell's own non-mandatory `n = 1` argument) and why no
  // MRB_SET_INSTANCE_TT call belongs here. No bare `private` anywhere in
  // the real source (confirmed directly, not guessed from bc2cpp's own
  // diagnostic), so every method below is `mrb_define_method`.
  RClass* shop = mrb_class_get_under(M, game, "Shop");
  mrb_define_method(M, shop, "allow_buy?", Game__Shop_allow_buy_,
                    MRB_ARGS_NONE());
  mrb_define_method(M, shop, "allow_sell?", Game__Shop_allow_sell_,
                    MRB_ARGS_NONE());
  mrb_define_method(M, shop, "price", Game__Shop_price, MRB_ARGS_REQ(1));
  // #name collides by bare name with mruby core's own Symbol#name/
  // Class#name (registered via `symbol_rom_entries`'s own MRB_MT_ENTRY
  // table, src/symbol.c -- invisible without NATIVE_SRCS pointed at
  // 3rd/mruby's own source) -- correctly registered here regardless
  // (registration is by class, not by bc2cpp's own MONO/POLY call-site
  // analysis), the collision only matters for whether some *other*
  // compiled call site may devirtualize straight into this _impl, which
  // bc2cpp's own whole-program diagnostic confirms it correctly refuses to
  // do (":name" reports POLY, 2 defs: Game::Shop, <native>).
  mrb_define_method(M, shop, "name", Game__Shop_name, MRB_ARGS_REQ(1));
  mrb_define_method(M, shop, "description", Game__Shop_description,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, shop, "equip?", Game__Shop_equip_, MRB_ARGS_REQ(1));
  mrb_define_method(M, shop, "sell_price", Game__Shop_sell_price,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, shop, "sellable?", Game__Shop_sellable_,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, shop, "sellable_items", Game__Shop_sellable_items,
                    MRB_ARGS_NONE());
  mrb_define_method(M, shop, "max_buy", Game__Shop_max_buy, MRB_ARGS_REQ(1));
  mrb_define_method(M, shop, "max_sell", Game__Shop_max_sell, MRB_ARGS_REQ(1));

  // Game::Map (mruby-rpg2k/mrblib/game.rb, reopened by mruby-rpg2k/mrblib/
  // game/battle_support.rb) -- see this file's own top comment for the
  // real gap breakdown (#substitute_tile's own two BLOCK/SENDB blocks) and
  // the real construction-site check backing the embedding below. @id and
  // @revision are real fields on a new Game__Map_ivars RData struct, mixed
  // safely with the rest of this class's own ivars on the ordinary
  // dynamic iv_tbl. Reuses the `game` RClass* declared at the top of this
  // function.
  RClass* map = mrb_class_get_under(M, game, "Map");
  MRB_SET_INSTANCE_TT(map, MRB_TT_DATA);

  // #initialize is always private (the same real interpreter special case
  // as every other compiled #initialize in this file -- mruby's own
  // src/class.c forces it regardless of source, not a bare `private` call
  // here).
  mrb_define_private_method(M, map, "initialize", Game__Map_initialize,
                            MRB_ARGS_REQ(2));
  mrb_define_method(M, map, "sync_layers_to_unit",
                    Game__Map_sync_layers_to_unit, MRB_ARGS_NONE());
  mrb_define_method(M, map, "in_bounds?", Game__Map_in_bounds_,
                    MRB_ARGS_REQ(2));
  mrb_define_method(M, map, "lower", Game__Map_lower, MRB_ARGS_REQ(2));
  mrb_define_method(M, map, "upper", Game__Map_upper, MRB_ARGS_REQ(2));
  mrb_define_method(M, map, "substituted?", Game__Map_substituted_,
                    MRB_ARGS_NONE());
  mrb_define_method(M, map, "substitution_snapshot",
                    Game__Map_substitution_snapshot, MRB_ARGS_NONE());
  mrb_define_method(M, map, "restore_substitutions",
                    Game__Map_restore_substitutions, MRB_ARGS_REQ(2));
  mrb_define_method(M, map, "set_lower", Game__Map_set_lower, MRB_ARGS_REQ(3));
  mrb_define_method(M, map, "set_upper", Game__Map_set_upper, MRB_ARGS_REQ(3));
  // #set_tile/#tile are both `private` in the real interpreted source (a
  // bare `private` mid-class-body in game.rb's own reopening, in effect
  // through the end of it) -- the same real visibility check this file's
  // own Game::Picture#step/#finish_move bug (docs/adr/0139) already
  // established the need for.
  mrb_define_private_method(M, map, "set_tile", Game__Map_set_tile,
                            MRB_ARGS_REQ(4));
  mrb_define_private_method(M, map, "tile", Game__Map_tile, MRB_ARGS_REQ(4));

  // Game::EnemyAi (mruby-rpg2k/mrblib/game/battle_support.rb) -- see this
  // file's own top comment for the real construction-site safety check and
  // why no MRB_SET_INSTANCE_TT call belongs here (both @db/@state are
  // opaque object references, never Fixnum/Symbol). No bare `private`
  // anywhere in the real source (confirmed directly, not guessed from
  // bc2cpp's own diagnostic), so every method below is `mrb_define_method`
  // except #initialize itself, which mruby's own src/class.c forces
  // private unconditionally regardless of source, the same always-private
  // special case as every other compiled #initialize in this file. Reuses
  // the `game` RClass* declared at the top of this function.
  RClass* enemy_ai = mrb_class_get_under(M, game, "EnemyAi");
  mrb_define_private_method(M, enemy_ai, "initialize", Game__EnemyAi_initialize,
                            MRB_ARGS_REQ(2));
  mrb_define_method(M, enemy_ai, "skill", Game__EnemyAi_skill, MRB_ARGS_REQ(1));
  mrb_define_method(M, enemy_ai, "enemy", Game__EnemyAi_enemy, MRB_ARGS_REQ(1));
  mrb_define_method(M, enemy_ai, "skill_command", Game__EnemyAi_skill_command,
                    MRB_ARGS_REQ(3));
  mrb_define_method(M, enemy_ai, "skill_helps_troop?",
                    Game__EnemyAi_skill_helps_troop_, MRB_ARGS_REQ(3));
  mrb_define_method(M, enemy_ai, "skill_battle_usable?",
                    Game__EnemyAi_skill_battle_usable_, MRB_ARGS_REQ(1));
  mrb_define_method(M, enemy_ai, "skill_ready?", Game__EnemyAi_skill_ready_,
                    MRB_ARGS_REQ(2));
  mrb_define_method(M, enemy_ai, "switch?", Game__EnemyAi_switch_,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, enemy_ai, "set_switch", Game__EnemyAi_set_switch,
                    MRB_ARGS_REQ(2));
  // #party_level is NOT registered here -- its own body ends in a real
  // `actors.each { |a| ... }` block (BLOCK/SENDB), an already-established
  // out-of-scope shape (see this file's own top comment, corrected: 9 of
  // this class's own 10 real methods compile clean, not all 10).

  // Game::ChipSet (mruby-rpg2k/mrblib/game.rb) -- see this file's own top
  // comment (compiled_gems.rb's own comment carries the full writeup) for
  // the real construction-site check backing the embedding below, and for
  // the real bitwise/modulo-operator SEND-name-extraction bug this class's
  // own #passable_tile?/#landable_tile? surfaced in bc2cpp.rb itself (also
  // live in RPG2k::Scene::ChipsetEditor#toggled_byte/#cell_color_for and
  // 30 other already-shipped methods, fixed at the root, no hand-edit
  // needed to any registration block). ALL 9 of its own real
  // bytecode-defined instance methods compile clean; `.lower_index` is a
  // real singleton method (`def self.lower_index`), structurally invisible
  // to bc2cpp's own registry (the same pre-existing gap Game::MoveRoute's
  // own class methods already documented), so it stays interpreted and
  // every call into it from a compiled method below correctly falls back
  // to ordinary dynamic dispatch rather than being (unsoundly)
  // devirtualized. @animation_type and @animation_speed are real fields on
  // a new Game__ChipSet_ivars RData struct, mixed safely with the rest of
  // this class's own (String/Array-typed, UNKNOWN) ivars on the ordinary
  // dynamic iv_tbl. Reuses the `game` RClass* declared at the top of this
  // function.
  RClass* chip_set = mrb_class_get_under(M, game, "ChipSet");
  MRB_SET_INSTANCE_TT(chip_set, MRB_TT_DATA);

  // #initialize is always private (the same real interpreter special case
  // as every other compiled #initialize in this file -- mruby's own
  // src/class.c forces it regardless of source, not a bare `private` call
  // here).
  mrb_define_private_method(M, chip_set, "initialize", Game__ChipSet_initialize,
                            MRB_ARGS_REQ(2));
  // #upper_flags is `private` via a real, explicit `private :upper_flags`
  // call right after its own def (not the bare mode-switch form every other
  // private section in this file uses) -- the same real visibility check
  // this file's own Game::Picture#step/#finish_move bug (docs/adr/0139)
  // already established the need for.
  mrb_define_private_method(M, chip_set, "upper_flags",
                            Game__ChipSet_upper_flags, MRB_ARGS_REQ(1));
  mrb_define_method(M, chip_set, "elevated?", Game__ChipSet_elevated_,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, chip_set, "passable?", Game__ChipSet_passable_,
                    MRB_ARGS_REQ(2));
  mrb_define_method(M, chip_set, "landable?", Game__ChipSet_landable_,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, chip_set, "counter?", Game__ChipSet_counter_,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, chip_set, "passable_tile?", Game__ChipSet_passable_tile_,
                    MRB_ARGS_REQ(3));
  mrb_define_method(M, chip_set, "landable_tile?", Game__ChipSet_landable_tile_,
                    MRB_ARGS_REQ(2));
  mrb_define_method(M, chip_set, "terrain", Game__ChipSet_terrain,
                    MRB_ARGS_REQ(1));

  // Game::Timer (mruby-rpg2k/mrblib/game.rb) -- see this file's own top
  // comment for the real gap breakdown (#start/#tick/#drawn?'s own
  // non-mandatory arguments) and why no MRB_SET_INSTANCE_TT call belongs
  // here (no embeddable ivar at all, per the real whole-program EMBED
  // diagnostic -- @frames is poisoned to UNKNOWN by #load_h's own opaque
  // Hash#[] read, and @running/@visible/@in_battle are booleans, a type
  // this compiler's embedding lattice doesn't model). No bare `private`
  // anywhere in the real source (confirmed directly, not guessed from
  // bc2cpp's own diagnostic), so every method below is `mrb_define_method`
  // except #initialize.
  RClass* timer = mrb_class_get_under(M, game, "Timer");

  // #initialize is always private (the same real interpreter special case
  // as every other compiled #initialize in this file -- mruby's own
  // src/class.c forces it regardless of source, not a bare `private` call
  // here).
  mrb_define_private_method(M, timer, "initialize", Game__Timer_initialize,
                            MRB_ARGS_NONE());
  mrb_define_method(M, timer, "set", Game__Timer_set, MRB_ARGS_REQ(1));
  mrb_define_method(M, timer, "stop", Game__Timer_stop, MRB_ARGS_NONE());
  mrb_define_method(M, timer, "seconds", Game__Timer_seconds, MRB_ARGS_NONE());
  mrb_define_method(M, timer, "to_h", Game__Timer_to_h, MRB_ARGS_NONE());
  mrb_define_method(M, timer, "load_h", Game__Timer_load_h, MRB_ARGS_REQ(1));
  mrb_define_method(M, timer, "display_text", Game__Timer_display_text,
                    MRB_ARGS_NONE());

  // Game::Switches (mruby-rpg2k/mrblib/game.rb) -- the 1-indexed boolean
  // flag store an event page's conditions are read from. Backed by a
  // plain Hash (`@data = {}`), not a real bit-array, so this class's own method
  // bodies never hit a bitwise/modulo operator SEND at all -- checked
  // directly, not assumed, against this file's own operator-regex bug
  // writeup above: #flip's own `!self[id]` is a real SEND too, to `!`,
  // but that character was already in the pre-fix charset. ALL 7 of its
  // own real bytecode-defined methods compile clean, needing no new
  // opcode work at all (#revision/#dirty are attr_reader-generated,
  // native, invisible to bc2cpp the same way every other attr_reader/
  // attr_writer in this codebase is). @revision is a real field on a new
  // Game__Switches_ivars RData struct, mixed safely with the rest of this
  // class's own (Hash-typed, UNKNOWN) ivars on the ordinary dynamic
  // iv_tbl. Checked directly against the exact Game::Actor-shaped
  // embedding bug several follow-ups up, not assumed safe by analogy:
  // grepping the whole closed world for `Switches.new`/
  // `Game::Switches.new`/`.allocate`/a subclass finds exactly two real
  // construction sites (mruby-rpg2k/mrblib/game.rb's own
  // Game::State#initialize and this project's own
  // scripts/export_nano7_map.rb harness), both plain zero-argument `.new`
  // calls, no bypass and no subclass anywhere. No bare
  // `private`/`protected`/`public` anywhere in the real source (confirmed
  // directly, not guessed from bc2cpp's own diagnostic), so every method
  // below is `mrb_define_method` except #initialize itself, which mruby's
  // own src/class.c forces private unconditionally regardless of source,
  // the same always-private special case as every other compiled
  // #initialize in this file.
  RClass* switches = mrb_class_get_under(M, game, "Switches");
  MRB_SET_INSTANCE_TT(switches, MRB_TT_DATA);
  mrb_define_private_method(M, switches, "initialize",
                            Game__Switches_initialize, MRB_ARGS_NONE());
  mrb_define_method(M, switches, "[]", Game__Switches___, MRB_ARGS_REQ(1));
  mrb_define_method(M, switches, "[]=", Game__Switches____, MRB_ARGS_REQ(2));
  mrb_define_method(M, switches, "flip", Game__Switches_flip, MRB_ARGS_REQ(1));
  mrb_define_method(M, switches, "to_h", Game__Switches_to_h, MRB_ARGS_NONE());
  mrb_define_method(M, switches, "replace", Game__Switches_replace,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, switches, "clear_dirty", Game__Switches_clear_dirty,
                    MRB_ARGS_NONE());

  // Game::Variables (same file, immediately below Switches) -- the
  // 1-indexed integer store the same page conditions read, clamped to a
  // fixed +-999999/+-9999999 range on write. Same Hash-backed, no-real-
  // bitwise-operator shape as Switches above (its own `[]=` clamp is a
  // plain pair of `>`/`<` sends against @max/@min, already covered by the
  // existing EQ/LT/LE/GT/GE opcode work). #initialize
  // (`initialize(rpg2003 = false)`) has one non-mandatory optional
  // argument -- the same established out-of-scope shape every other
  // unembedded target in this file documents -- so it stays interpreted
  // and drop_unsafe_embeddings correctly refuses to embed this class's own
  // provably-Fixnum @revision too: no MRB_SET_INSTANCE_TT call belongs in
  // this registration block, and no DATA_PTR(self) access appears in any
  // of its own compiled methods below. The other 5 of its own 6 real
  // bytecode-defined methods compile clean, needing no new opcode work at
  // all. No bare `private`/`protected`/`public` anywhere in the real
  // source, so every method below is `mrb_define_method`.
  RClass* variables = mrb_class_get_under(M, game, "Variables");
  mrb_define_method(M, variables, "[]", Game__Variables___, MRB_ARGS_REQ(1));
  mrb_define_method(M, variables, "[]=", Game__Variables____, MRB_ARGS_REQ(2));
  mrb_define_method(M, variables, "to_h", Game__Variables_to_h,
                    MRB_ARGS_NONE());
  mrb_define_method(M, variables, "replace", Game__Variables_replace,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, variables, "clear_dirty", Game__Variables_clear_dirty,
                    MRB_ARGS_NONE());

  // RPG2k::Scene::Title (mruby-rpg2k/mrblib/scene/title.rb) -- see
  // compiled_gems.rb's own comment on this gem's `owners:` entry for the
  // full writeup, including the real gap breakdown (13 rescue clauses;
  // #initialize's own SUPER + BLOCK double gap) and why no
  // MRB_SET_INSTANCE_TT call belongs here. #refresh_cursor is genuinely
  // POLY at every real call site (RPG2k::Scene::Menu defines a same-named
  // method too), so #move_selection's own call into it correctly stays
  // ordinary mrb_funcall dispatch rather than being devirtualized.
  // #update/#dispose are mrb_define_method; #refresh_cursor/
  // #move_selection/#auto_select?/#auto_new_game? are all
  // mrb_define_private_method (the real bare `private` mode-switch
  // mid-class-body, in effect through the end of the class), confirmed
  // directly against the real source. Reuses the `scene` RClass* declared
  // at the top of this function.
  RClass* title = mrb_class_get_under(M, scene, "Title");
  mrb_define_method(M, title, "update", RPG2k__Scene__Title_update,
                    MRB_ARGS_NONE());
  mrb_define_method(M, title, "dispose", RPG2k__Scene__Title_dispose,
                    MRB_ARGS_NONE());
  mrb_define_private_method(M, title, "refresh_cursor",
                            RPG2k__Scene__Title_refresh_cursor,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, title, "move_selection",
                            RPG2k__Scene__Title_move_selection,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, title, "auto_select?",
                            RPG2k__Scene__Title_auto_select_, MRB_ARGS_NONE());
  mrb_define_private_method(M, title, "auto_new_game?",
                            RPG2k__Scene__Title_auto_new_game_,
                            MRB_ARGS_NONE());

  // RPG2k::Scene::MapWorld (mruby-rpg2k/mrblib/scene/base.rb) -- see this
  // file's own top comment for the real construction-site safety check and
  // why no MRB_SET_INSTANCE_TT call belongs here (both @scene/@rng are
  // opaque object references, never Fixnum/Symbol). No bare
  // `private`/`protected` anywhere in the real source, so every method
  // below is `mrb_define_method` except #initialize itself, which mruby's
  // own src/class.c forces private unconditionally regardless of source,
  // the same always-private special case as every other compiled
  // #initialize in this file. Reuses the `scene` RClass* declared at the
  // top of this function.
  RClass* map_world = mrb_class_get_under(M, scene, "MapWorld");
  mrb_define_private_method(M, map_world, "initialize",
                            RPG2k__Scene__MapWorld_initialize, MRB_ARGS_REQ(2));
  mrb_define_method(M, map_world, "passable?", RPG2k__Scene__MapWorld_passable_,
                    MRB_ARGS_REQ(2));
  mrb_define_method(M, map_world, "can_land?", RPG2k__Scene__MapWorld_can_land_,
                    MRB_ARGS_REQ(3));
  mrb_define_method(M, map_world, "hero_position",
                    RPG2k__Scene__MapWorld_hero_position, MRB_ARGS_NONE());
  mrb_define_method(M, map_world, "in_sight?", RPG2k__Scene__MapWorld_in_sight_,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, map_world, "set_switch",
                    RPG2k__Scene__MapWorld_set_switch, MRB_ARGS_REQ(2));
  mrb_define_method(M, map_world, "random", RPG2k__Scene__MapWorld_random,
                    MRB_ARGS_REQ(1));
  // #play_sound is NOT registered here -- its own body has a real `rescue
  // StandardError` clause (RESCUE/RAISEIF/EXCEPT), an already-established
  // out-of-scope shape (see this file's own top comment).
}

extern "C" void mrb_mruby_rpg2k_compiled_gem_final(mrb_state*) {}
