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
// A twenty-second, independent round adds RPG2k::Scene::VehicleWorld
// (mruby-rpg2k/mrblib/scene/base.rb, defined right below MapWorld) -- the
// same `world` protocol adapter MapWorld exposes to the movement engine,
// adapted for a Move Event/Set Move Route driving a vehicle (boat/ship/
// airship) instead of the hero: passability/landing route through
// Scene::Map#vehicle_char_passable?/#vehicle_char_can_land? (each
// carrying the extra @type argument) instead of MapWorld's own
// #char_passable?/#char_can_land?, and there is no #in_sight?
// counterpart at all (not a gap -- Approach/Away from Player is not a
// valid Move Type for a vehicle's own Set Move Route, confirmed directly
// against the real source comment). 6 of its own 7 real bytecode-defined
// methods compile clean, needing no new opcode work at all. #play_sound
// is the one gap, confirmed against its own real generated #error lines
// (EXCEPT/RESCUE/RAISEIF): a real `rescue StandardError => e` clause, the
// same already-established out-of-scope shape as MapWorld's own
// identically-shaped #play_sound.
//
// #initialize (`initialize(scene, rng, type)`, already carrying its own
// real `# bc2cpp: (RPG2k::Scene::Map, Game::Rng, Symbol)` magic-comment
// annotation in the source) compiles clean -- 3 purely mandatory
// arguments, no super, no block -- so its own @type ivar (always a
// literal Symbol from Game::Vehicle::TYPES, confirmed by the annotation
// and by the real whole-program EMBED diagnostic) gets real RData struct
// embedding, the third Symbol-embedding target after Game::ChipSet/
// Game::Switches's own Fixnum embeddings established the mechanism, here
// for a Symbol instead. Checked directly against the exact
// Game::Actor-shaped embedding bug several follow-ups up, not assumed
// safe by analogy: grepping the whole closed world for
// `VehicleWorld.new`/`.allocate`/a subclass finds exactly one real
// construction site (mruby-rpg2k/mrblib/scene/map.rb's own `#load_map`,
// `h[type] = VehicleWorld.new(self, @rng, type)` inside a
// `Game::Vehicle::TYPES.each_with_object` loop), a plain three-argument
// `.new` call, no bypass and no subclass anywhere -- and the real
// generated #initialize body was confirmed to call mrb_data_init before
// any other statement. @scene and @rng stay on the ordinary dynamic
// iv_tbl (both opaque object references, CLASS_HINT-typed for
// devirtualization only, never embedded), mixed safely on the same
// object with the one embedded field.
//
// A real, whole-program MONO/POLY registry-soundness gap was found (and
// deliberately left unfixed, out of this round's own scope) while
// verifying #set_switch's own `@scene.state.switches[id] = on`:
// `:switches` has exactly one bytecode-visible definition anywhere in
// the closed world (Game::Interpreter#switches, itself `@state.
// switches`), so an unrestricted whole-program diagnostic (no
// ONLY_OWNERS) reports it MONO and would devirtualize this call straight
// into Game__Interpreter_switches_impl -- but every real call site in
// the whole codebase actually sends it to a Game::State instance, whose
// own real `:switches` is an attr_reader installed at runtime via a
// Symbol argument to Module#attr_reader, never a literal
// mrb_define_method-family call site, so it is structurally invisible to
// extract_native_method_names's own regex-based scanner regardless of
// NATIVE_SRCS. Had this actually been devirtualized, it would be real
// infinite recursion (Game::Interpreter#switches' own body devirtualizes
// right back into itself when called with a Game::State receiver,
// confirmed directly against the real generated code) -- the same
// failure mode Game::MoveRoute#empty? already documented, against a
// different structural blind spot (attr_reader/attr_writer, not a native
// mrb_define_method call site or an MRB_MT_ENTRY/MRB_SYM(_Q/_B/_E)
// ROM-table entry, the two shapes extract_native_method_names already
// covers). Verified NOT live in the real build, not just reasoned about:
// Game::Interpreter is not in this gem's own ONLY_OWNERS (nor any other
// compiled gem's OTHER_OWNERS), so compile_send's own already-established
// owner-not-emitted guard correctly refuses the devirtualization and
// falls back to ordinary mrb_funcall -- confirmed directly against the
// real generated output with ONLY_OWNERS set exactly as this gem's own
// mrbgem.rake sets it: #set_switch's own `.switches` send compiles to
// plain `mrb_funcall(M, r5, "switches", 0)`, never a direct call.
// Flagged here for whoever next adds Game::Interpreter (or any other
// attr_reader-heavy class) to a compiled gem's own owners list --
// extract_native_method_names would need a third scanning mode (a
// literal `attr_reader`/`attr_writer`/`attr_accessor` call-site scan
// across every real .rb source file, not just C/C++) before that could
// ever be safe.
//
// A twenty-third, independent round adds Game::TextReveal
// (mruby-rpg2k/mrblib/game.rb) -- the message-window character-by-
// character text reveal/typewriter-effect backing model: `\!`/`\.`/`\|`
// pause markers, `\^` auto-close, `\>`...`\<` instant spans, `\s[n]`
// speed changes. Only 6 of its own 11 real bytecode-defined methods
// compile clean, needing no new opcode work at all: #auto_close? (a bare
// ivar read), #done? (a plain GE compare against @total), #reveal_all (a
// MONO self-call into #next_pause, a Hash#[] GETIDX read on the pause it
// returns, and a ternary), #next_pause (an Array GETIDX read),
// #pending_pause (the same Array GETIDX read plus a Hash#[] GETIDX read
// and a GE compare), and #release_pause (a MONO self-call into
// #pending_pause plus an ADDI increment) -- all confirmed directly
// against the real generated output, including a specific re-check for
// this file's own operator-regex bug (none of these six bodies uses a
// bitwise/modulo operator SEND at all, so nothing here could trigger it
// either way; the project-wide zero-match empty-name grep covers it
// regardless). #initialize (`lines, revealed = 0, pauses = [],
// auto_close = false, instants = [], speeds = []`, five optional
// arguments) and #advance (`n = 1`, one optional argument) both have the
// same established non-mandatory-arity gap as every other unembedded
// target above. #speed_at, #through_instant and #visible_lines each end
// in a genuine Ruby block, BLOCK/SENDB, the same established out-of-
// scope shape every other block-using method above already documents.
//
// #initialize never compiling means drop_unsafe_embeddings correctly
// refuses to embed any of this class's own ivars, even though the raw,
// class-blind IvarLayout analysis proposes two (@total/@released, both
// provably-Fixnum): confirmed directly against the real generated
// output, Game::TextReveal does not appear in bc2cpp's own "classes
// needing MRB_SET_INSTANCE_TT" diagnostic, so no MRB_SET_INSTANCE_TT
// call belongs here, and no DATA_PTR(self) access appears in any of its
// own compiled methods below.
//
// No bare `private`/`protected`/`public` anywhere in the real source, so
// every method below is `mrb_define_method`; #initialize itself stays
// entirely interpreted (it never compiles), so it needs no registration
// line at all here, unlike every other target in this file whose own
// #initialize does compile.
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
//
// A real, live, already-shipped bug (docs/adr/0139's own follow-up,
// found doing the diligence work for a later mruby-lcf-compiled target,
// LCF::EventCommand, whose own `attr_reader :code, :indent, ...`
// reproduced the exact same shape small enough to catch): bc2cpp.rb's
// drop_unsafe_embeddings guard checked only whether #initialize itself
// compiles clean -- never whether some OTHER, native accessor for the
// very same ivar name already exists on that class. A plain
// `attr_reader`/`attr_writer`/`attr_accessor` is exactly that: its real
// C implementation (3rd/mruby/src/class.c's own `attr_reader`/
// `attr_writer`) is a bare `mrb_iv_get`/`mrb_iv_set` against the
// ordinary dynamic `iv_tbl`, with no way to know this class's own SETIV
// codegen wrote the value into an embedded `RData` struct field instead
// -- so the native getter always read back `nil` (or the setter's own
// write was simply invisible to every compiled GETIV reader) regardless
// of what #initialize did, the moment an embedded ivar's own bare name
// collided with one of these. Four already-shipped classes below hit
// this for real, not hypothetically: Game::State's own `attr_accessor
// :map, :x, :y, :direction` silently broke every compiled instance's
// real `#x`/`#y`/`#direction` (the hero's own position/facing, read
// constantly by the movement engine) the moment @x/@y/@direction were
// embedded; Game::Map's own `attr_reader :id, ..., :revision` did the
// same to `#id`/`#revision` (the tile-layer cache-invalidation counter
// Scene::Map#tile_cache_valid? watches); Game::ChipSet's own
// `attr_reader :name, :graphic, :animation_type, :animation_speed` did
// the same to `#animation_type`/`#animation_speed`; Game::Switches's own
// `attr_reader :revision` did the same to `#revision` (the exact counter
// mruby-rpg2k/mrblib/game.rb's own comment says the map scene watches to
// know when an event page's conditions might have flipped). All four
// compiled and linked clean, zero warnings -- confirmed for real with a
// minimal toy repro (a class embedding one ivar via a compiling
// #initialize, with a plain `attr_reader` installed for it the ordinary
// way): `Foo.new(42).x` returns `nil`, not `42`, once embedded, run
// directly against this project's own real mruby core build. Fixed in
// bc2cpp.rb itself: drop_unsafe_embeddings now also drops any individual
// ivar name that collides with a same-owner, same-name synthetic
// (irep-nil) MethodDef -- the exact registry entry build_registry's own
// attr_reader/writer/accessor case already installs -- rather than only
// gating at the whole-owner level. This can only ever remove an embedding
// that was never safe to begin with; it cannot turn a real embedding
// unsound the other way. Confirmed directly against the regenerated
// output: none of these four classes appear in bc2cpp's own "classes
// needing MRB_SET_INSTANCE_TT" diagnostic anymore, no `Game__State_ivars`/
// `Game__Map_ivars`/`Game__ChipSet_ivars`/`Game__Switches_ivars` struct is
// generated for any of them, and every real ivar access in their own
// compiled methods below (#initialize included) reads/writes the
// ordinary dynamic iv_tbl via plain `mrb_iv_get`/`mrb_iv_set` -- so the
// `MRB_SET_INSTANCE_TT(..., MRB_TT_DATA)` calls this file used to make
// for these four classes are removed below too (each one's own real
// #initialize is otherwise completely unaffected -- same arity, same
// visibility, same registered entry points).
//
// A later round adds Game::Interpreter (docs/adr/0139's own follow-up) as
// this gem's 61st owner -- 173 of its own 207 real bytecode-defined
// methods, by far the largest single class this gem covers, and a real,
// previously-shipped severe bug found and fixed along the way. Building
// out `drop_unsafe_embeddings`'s own #initialize-only compileability gate
// into a real per-ivar `every_accessor_compiles?` check (does *every*
// method that ever touches this exact ivar, nested block bodies included,
// also compile clean -- not just #initialize) surfaced a live instance of
// the same class of bug this file's own Game::Actor writeup already fixed
// once, this time triggered by a different method than #initialize failing
// to compile: Game::Transition's own @width/@height were real embedded
// struct fields, correct for #initialize and every compiling reader, but 6
// of Transition's own real methods (#block_rects/#blind_rects/
// #vertical_stripe_rects/#horizontal_stripe_rects/#clip/
// #compute_block_order, all real Ruby-block users) also read one or both
// -- entirely outside any compiled codegen's view -- and stayed on the
// interpreter, which still reads/writes the same ivar name through the
// object's own separate, never-populated dynamic `iv_tbl` (`struct RData`
// carries one independently of the `data` pointer this compiler's embedded
// struct lives behind -- confirmed directly against 3rd/mruby/include/
// mruby/data.h). Every real call to any of those 6 methods against an
// already-constructed Game::Transition would have read a permanently-nil
// @width/@height instead of the value #initialize actually set -- a real,
// live crash (`#clip`'s own `x >= @width` raising `NoMethodError` on nil)
// in already-merged code, not a missed optimization. See that class's own
// registration block below for the full writeup; the fix itself lives in
// tools/bc2cpp/bc2cpp.rb. Re-ran this gem's own real bc2cpp invocation
// before/after the fix with Game::Interpreter still excluded from
// `owners:` -- confirmed the *only* change anywhere in the whole
// regenerated file is Game::Transition's own @width/@height losing their
// embedding; every other already-shipped class's own generated output,
// entry-point count, and registration is byte-for-byte unaffected.
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
  // drop_unsafe_embeddings guard does NOT refuse to embed here.
  //
  // Only 10 of Screen's own ivars are real struct fields on a
  // `Game__Screen_ivars*` RData payload today -- @flash_r/@flash_g/
  // @flash_b/@flash_power/@flash_strength/@flash_total, @pan_tx/@pan_ty,
  // @fade/@fade_target -- confirmed directly against both the real
  // `Game__Screen_ivars` struct definition and the per-field `// @X
  // embedded (fixnum) -- direct struct field ...` markers bc2cpp emits at
  // every read/write site in the real regenerated output, not assumed from
  // #initialize's own source shape. That means #initialize's own compiled
  // body calls mrb_data_init on `self` -- which mruby's own mrb_data_init
  // (mruby/data.h) asserts is already MRB_TT_DATA
  // (`mrb_assert(mrb_data_p(v))`) -- so the class itself has to be tagged
  // MRB_TT_DATA *before* any Game::Screen.new can ever run, exactly the
  // same real requirement mruby-rgss/src/lib.cxx's own natively-implemented
  // classes (Sprite, Rect, Viewport, ...) already meet via their own
  // MRB_SET_INSTANCE_TT calls -- the first time a *-compiled gem needs this
  // (neither mruby-lcf-compiled's nor this gem's own Picture/EnemyAction
  // blocks above ever embed anything, so neither one has ever needed it
  // before).
  //
  // This paragraph used to claim 21 embedded ivars (also listing @frames,
  // @shake_power/@shake_speed/@shake_frames/@shake_offset, @flash_frames,
  // @pan_x/@pan_y/@pan_step, @fade_frames/@fade_transition) -- accurate
  // when this class was first added here (all 21 genuinely looked
  // Fixnum-only from #initialize's own literal SETIVs alone), but stale
  // after a same-day, unrelated fix to `IvarLayout.join` (docs/adr/0139's
  // own Game::Character follow-up, "fix live IvarLayout.join embedding
  // bug") started correctly poisoning an ivar to UNKNOWN the moment *any*
  // real write site anywhere else in the class -- not just #initialize --
  // is not provably Fixnum, and nobody revisited this comment once that
  // narrowed Screen's own real embedded set down to 10. Confirmed each of
  // the 11 removed names really does have such a site, not merely assumed
  // stale: e.g. `@pan_x = approach(@pan_x, @pan_tx, @pan_step)`/
  // `@pan_y = approach(...)` in #update_pan (a private self-call's opaque
  // return value -- also explains why @pan_x/@pan_y themselves may sit at
  // a sub-pixel value mid-pan per that method's own comment, unlike
  // @pan_tx/@pan_ty, which are only ever literal-`0`- or
  // `h[:key] || default`-assigned and stay embedded); `@shake_power =
  // Game.clamp(power, 0, 9)`/`@shake_offset = Game.clamp(newpos, ...)` (a
  // POLY call's return value, same shape); `@shake_frames = frames`/
  // `@frames = frames`/`@flash_frames = frames` (an opaque mandatory
  // argument, never annotated or provably Fixnum at every call site); and
  // `@fade_transition = style` (same argument shape). This is a
  // documentation-drift finding only -- the actual embedded set, the
  // MRB_SET_INSTANCE_TT call, and every GETIV/SETIV site's own choice of
  // struct-field-vs-iv_tbl were already correct; only this comment's list
  // of *which* ivars was wrong.
  //
  // The remaining real ivars (@r/@g/@b/@sat/@tr/@tg/@tb/@tsat -- their own
  // source is Game.clamp's return value or the NEUTRAL constant, neither
  // traced by bc2cpp's Fixnum-literal-only type inference;
  // @shake_continuous/@flash_continuous/@pan_locked -- booleans, a type
  // this compiler's embedding lattice doesn't model at all; @transition --
  // a real Game::Transition object reference, never primitive; plus the 11
  // now-UNKNOWN ivars named above) stay on the ordinary dynamic iv_tbl,
  // read/written through the interpreter's own mrb_iv_get/mrb_iv_set
  // exactly as before -- safe to mix with the 10 embedded fields on the
  // very same object: every compiled method's own GETIV/SETIV already
  // knows, per ivar, whether it's an embedded struct field or an ordinary
  // iv_tbl entry (bc2cpp's ivar_layout keyed lookup), so nothing here has
  // to track which is which by hand.
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
  // Game::Screen above) drop_unsafe_embeddings does NOT refuse this class
  // outright. @style/@frames/@frame do NOT embed: this class carries a bare
  // `attr_reader :style, :frames, :frame` (mruby-rpg2k/mrblib/game.rb,
  // right above #initialize) that collides with exactly those three names,
  // the same attr_reader/embedded-ivar shape `natively_exposed?`/
  // `drop_unsafe_embeddings` (this ADR's own eighth severe bug fix) exists
  // to catch.
  //
  // Neither @width nor @height embeds either, as of docs/adr/0139's own
  // Game::Interpreter follow-up -- a real, previously-shipped, LIVE memory-
  // safety bug this round's own generalized `drop_unsafe_embeddings` fix
  // found and closed, not merely a documentation drift like the paragraph
  // this replaces. Before that fix, both were real struct fields on a
  // `Game__Transition_ivars*` RData payload (`MRB_SET_INSTANCE_TT
  // (transition, MRB_TT_DATA)`, no longer called here) -- correctly so for
  // every one of #initialize's own writes and every *compiled* reader, but
  // wrong for the 6 real methods that never compile at all (BLOCK/SENDB:
  // #block_rects, #blind_rects, #vertical_stripe_rects,
  // #horizontal_stripe_rects, #clip, #compute_block_order -- see this
  // file's own top comment). `#blind_rects`'s own `bands = @height /
  // BLIND_BAND` reads @height at the method's own top level, *before* its
  // trailing `bands.times do |i| ... end` block even starts; `#clip`'s own
  // `rects.each do |x, y, w, h| ... @width ... @height ... end` reads both
  // only *inside* that block's own separate child irep, invisible to a
  // scan of #clip's own top-level irep alone (6 instructions: build the
  // Array, MOVE the argument, `#error unhandled opcode BLOCK` -- it never
  // itself mentions either ivar). Either way, since none of these 6 methods
  // ever compiles, every one of them keeps running mruby-rpg2k's own
  // interpreted mrblib body -- which still executes an ordinary SETIV/
  // GETIV against the object's own dynamic `iv_tbl` (mrb's own `struct
  // RData` carries one, entirely separate from the `data` pointer this
  // compiler's embedded struct lives behind -- confirmed directly against
  // 3rd/mruby/include/mruby/data.h). Since a compiled #initialize's own
  // embedded-field write never touches that `iv_tbl` at all, every real
  // call to any of these 6 methods against a real, already-constructed
  // Game::Transition would have read a permanently-nil `@width`/`@height`
  // instead of the value #initialize actually set -- e.g. `#clip`'s own
  // `x >= @width` raising `NoMethodError` (nil has no `>=`) the first time
  // any real screen transition ever clipped a rect, a live crash in
  // already-merged code, not a missed optimization. `every_accessor_
  // compiles?` (tools/bc2cpp/bc2cpp.rb) now refuses to embed an ivar unless
  // *every* method that ever touches it -- its own nested block bodies
  // included, not just its own top-level irep -- also compiles clean;
  // re-running this gem's own real bc2cpp invocation before/after that fix
  // (owners: unchanged, `Game::Interpreter` not yet added) confirms the
  // *only* change anywhere in the whole regenerated file is exactly this:
  // @width/@height drop out of the `Game__Transition_ivars` struct (which
  // no longer exists at all, since nothing else on this class was ever
  // embedded) and every read/write of them across #initialize and the 12
  // other real methods that reference either one (#block_grid_cols,
  // #visible_rects, #capture_ops, #scroll_offset, #vertical_split_ops,
  // #horizontal_split_ops, #cross_split_ops, #zoom_rect,
  // #border_to_center_rect, #center_to_border_rect, #around) falls back to
  // plain `mrb_iv_get`/`mrb_iv_set` -- every one of those methods' own
  // arity/visibility/registration below is completely unaffected, only the
  // ivar access path underneath changed, the identical "confirm nothing
  // else moved" shape this same file's own Game::Actor `drop_unsafe_
  // embeddings` bug-fix writeup already established. The one other real,
  // non-Fixnum ivar, @erase (a plain boolean set once in #initialize and
  // read by #black_alpha/#vertical_stripe_rects/#horizontal_stripe_rects),
  // was never embedded either way -- this compiler's embedding lattice
  // models Fixnum/Symbol, not booleans.
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
  // main ~2,100-line body), then 9 of the 13 more the class reopening in
  // mruby-rpg2k/mrblib/game/battle_support.rb adds -- a real, confirmed
  // documentation gap this round's own re-check of that reopening found
  // and closed: an earlier version of this comment said "the 9 methods"
  // as if that reopening (`class Actor` there, lines 14-198) defined only
  // 9 real methods total, when it actually defines 13 -- the other 4
  // (#states=, #prevents_critical?, #state_resist_mul,
  // #physical_evasion_up?) were simply never named as staying
  // interpreted. See this block's own note just above the 9 registrations
  // below for the real, re-verified reason each of those 4 still doesn't
  // compile. Every one of the 9 registered below is public in the real
  // interpreted source -- confirmed directly (not guessed from bc2cpp's
  // own diagnostic): battle_support.rb's own `class Actor` reopening has
  // no `private`/`protected` anywhere in it, and game.rb's own single
  // `private` for this class (line 3496) only covers the 5 methods
  // registered via mrb_define_private_method at the end of this block
  // below (plus #calc_exp, which still doesn't compile even after this
  // round's own RANGE_INC addition -- it also uses a real Ruby block,
  // BLOCK/SENDB, genuinely out of this compiler's scope -- so it has no
  // entry here at all, still running mruby-rpg2k's own interpreted body).
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

  // 9 of the 13 real methods mruby-rpg2k/mrblib/game/battle_support.rb's
  // own `class Actor` reopening adds (see this block's own intro comment
  // -- no `private` anywhere in that reopening, so all 9 are public here
  // too).
  //
  // The other 4 real methods that reopening defines all stay interpreted,
  // confirmed directly against each one's own real `#error` marker
  // (SKIP_UNSUPPORTED=0), not merely guessed from reading the Ruby source:
  // every one ends in a genuine Ruby block, the same established
  // BLOCK/SENDB out-of-scope shape every other block-using method in this
  // file already documents, not a missing opcode --
  //   - #states=(ids): `(ids || []).reject { |s| s.nil? || s == 0 }.uniq`
  //     -- the `.reject { |s| ... }` call is the block. POLY in the
  //     whole-program registry (2 defs: this class, Game::Battle::Combatant
  //     -- irrelevant here regardless, since the method never reaches
  //     codegen far enough for MONO/POLY dispatch mode to matter).
  //   - #prevents_critical?: `@equipment.any? do |iid| ... end`.
  //   - #state_resist_mul(sid): `@equipment.each do |iid| ... end`.
  //   - #physical_evasion_up?: `@equipment.any? do |iid| ... end`, the
  //     identical shape to #prevents_critical? above (a different block
  //     body, same Array#any? call site).
  // #prevents_critical?/#state_resist_mul/#physical_evasion_up? are each
  // MONO (1 def: Game::Actor) in the whole-program registry -- confirmed
  // directly, not assumed, though (like #states= above) it has no bearing
  // on any of these four, none of which ever gets far enough into codegen
  // to need a dispatch-mode decision at all.
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
  // #insert_item_in_bag family, plus #stat_mode -- a real, confirmed fix
  // to this comment's own prior wording, which mistakenly filed #stat_mode
  // under "the battle_support.rb reopening's own" methods just below: it
  // is not part of that reopening at all, it is `Game::Party#stat_mode`
  // in game.rb's own ~2,300-line main class body (`def stat_mode` at
  // game.rb line 5716, well before the `class Party` body ends), just
  // another one of this same "25 use a real Ruby block" group -- and the
  // battle_support.rb reopening's own #hit_modifier/#do_nothing_restricted?/
  // #skill_helps_troop?/#battle_skills/#skill_attributes/
  // #skill_stat_mod_keys/#battle_items),
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
  // #open_map_viewer has TWO independent gaps, one per branch of its own
  // `if @state.map && ... / ... else ... end` -- a documentation-accuracy
  // check re-confirming every "rescue" comment in this ADR against its
  // own real generated #error marker (docs/adr/0139's own follow-up)
  // caught the previous, incomplete version of this comment naming only
  // the second: the `else` branch's `map = begin ... rescue
  // StandardError => e ... end` (RESCUE/RAISEIF/EXCEPT) is real, but the
  // `if` branch's own `Scene::MapViewer.new(@parent, @state, map:
  // @state.map)` hits a completely different, unrelated gap first -- a
  // keyword-argument call site (`#error SEND/SSEND :new has a splat
  // and/or keyword argument list`, the same shape this ADR's own third-
  // severe-bug follow-up already named and fixed at the root). Confirmed
  // directly against the real generated output, not assumed: both
  // `#error` markers are present, in program order, before either
  // `RESCUE`/`RAISEIF`/`EXCEPT` marker. Both are already-established,
  // permanently-out-of-scope shapes on their own; naming only one matters
  // here because a future round that added real RESCUE/RAISEIF/EXCEPT
  // opcode support would still find this method blocked by the unrelated
  // keyword-argument gap in its own untaken branch -- worth knowing
  // before spending that work expecting this method to unlock.
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
  // breakdown. #initialize does compile clean, but its own @x/@y/
  // @direction no longer embed into an RData struct -- see this file's
  // own top comment for the real, already-shipped attr_reader/embedded-
  // ivar collision bug this class hit (`attr_accessor :map, :x, :y,
  // :direction` silently missed every compiled #x/#y/#direction while
  // those three were embedded) and its fix; no MRB_SET_INSTANCE_TT call
  // belongs here anymore. No bare `private` anywhere in either source
  // file (confirmed directly, not guessed from bc2cpp's own diagnostic),
  // so every method below is `mrb_define_method` except #initialize
  // itself, which mruby's own src/class.c forces private unconditionally
  // regardless of source, the same always-private special case as every
  // other shipped target's own #initialize.
  //
  // `bgm_chunk`/`se_chunk` (both below) are lsd_io.rb's own real
  // *instance* methods (a hash-field read, `||` defaults, no block/
  // rescue/super) -- both mandatory-arity-1 and already covered here. A
  // dedicated later round (docs/adr/0139's own "Game::State (lsd_io.rb
  // save/load) coverage investigation" follow-up) confirmed that file's
  // own remaining 9 real methods (`.tile_replacement_bytes`,
  // `.tile_replacement_hash`, `.build_event_exec_state`,
  // `.read_event_exec_frames`, `.from_lsd`, `.restore_pictures`,
  // `.ole_now`, `.bgm_from_chunk`, `.se_from_chunk`) are every one a
  // `def self.foo` class method, and confirmed directly (not by analogy)
  // that none of the 9 can ever be registered here regardless of its own
  // body: even with `Game::State.singleton` added to `ONLY_OWNERS` and
  // `SKIP_UNSUPPORTED=0`, bc2cpp emits zero output -- no declaration, no
  // `#error` stub -- for any of the 9, the same `.singleton` pseudo-owner
  // structural non-emittability this ADR's own `RGSS::Font` follow-up
  // already established. See compiled_gems.rb's own Game::State writeup
  // for the full per-method breakdown (4 real blocks, 2 real `rescue`
  // clauses, and 2 -- `.bgm_from_chunk`/`.se_from_chunk` -- that would
  // likely compile if this compiler ever gained a way to emit a
  // `.singleton`-owned method at all).
  RClass* state = mrb_class_get_under(M, game, "State");

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
  // real gap breakdown (#substitute_tile's own two BLOCK/SENDB blocks).
  // @id and @revision no longer embed into an RData struct -- see this
  // file's own top comment for the real, already-shipped attr_reader/
  // embedded-ivar collision bug this class hit (`attr_reader :id, ...,
  // :revision` silently missed every compiled #id/#revision while those
  // two were embedded) and its fix; no MRB_SET_INSTANCE_TT call belongs
  // here anymore. Reuses the `game` RClass* declared at the top of this
  // function.
  RClass* map = mrb_class_get_under(M, game, "Map");

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
  // devirtualized. @animation_type and @animation_speed no longer embed
  // into an RData struct -- see this file's own top comment for the real,
  // already-shipped attr_reader/embedded-ivar collision bug this class
  // hit (`attr_reader :name, :graphic, :animation_type, :animation_speed`
  // silently missed every compiled #animation_type/#animation_speed while
  // those two were embedded) and its fix; no MRB_SET_INSTANCE_TT call
  // belongs here anymore. Reuses the `game` RClass* declared at the top
  // of this function.
  RClass* chip_set = mrb_class_get_under(M, game, "ChipSet");

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
  // attr_writer in this codebase is -- which is exactly why @revision no
  // longer embeds into an RData struct either: see this file's own top
  // comment for the real, already-shipped attr_reader/embedded-ivar
  // collision bug this class hit -- `attr_reader :revision` silently
  // missed every compiled #revision while it was embedded -- and its
  // fix; no MRB_SET_INSTANCE_TT call belongs here anymore). Checked
  // directly against the exact Game::Actor-shaped embedding bug several
  // follow-ups up, not assumed safe by analogy: grepping the whole closed
  // world for `Switches.new`/`Game::Switches.new`/`.allocate`/a subclass
  // finds exactly two real construction sites (mruby-rpg2k/mrblib/game.rb's
  // own Game::State#initialize and this project's own
  // scripts/export_nano7_map.rb harness), both plain zero-argument `.new`
  // calls, no bypass and no subclass anywhere. No bare
  // `private`/`protected`/`public` anywhere in the real source (confirmed
  // directly, not guessed from bc2cpp's own diagnostic), so every method
  // below is `mrb_define_method` except #initialize itself, which mruby's
  // own src/class.c forces private unconditionally regardless of source,
  // the same always-private special case as every other compiled
  // #initialize in this file.
  RClass* switches = mrb_class_get_under(M, game, "Switches");
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

  // RPG2k::Scene::VehicleWorld (mruby-rpg2k/mrblib/scene/base.rb) -- see
  // this file's own top comment for the real construction-site safety
  // check, the Symbol-embedding writeup, and the real (checked-but-not-
  // fixed) attr_reader registry-soundness gap #set_switch surfaced.
  // #initialize is always private (the same real interpreter special case
  // as every other compiled #initialize in this file). No bare
  // `private`/`protected`/`public` anywhere in the real source, so every
  // other method below is `mrb_define_method`. Reuses the `scene` RClass*
  // declared at the top of this function.
  RClass* vehicle_world = mrb_class_get_under(M, scene, "VehicleWorld");
  MRB_SET_INSTANCE_TT(vehicle_world, MRB_TT_DATA);
  mrb_define_private_method(M, vehicle_world, "initialize",
                            RPG2k__Scene__VehicleWorld_initialize,
                            MRB_ARGS_REQ(3));
  mrb_define_method(M, vehicle_world, "passable?",
                    RPG2k__Scene__VehicleWorld_passable_, MRB_ARGS_REQ(2));
  mrb_define_method(M, vehicle_world, "can_land?",
                    RPG2k__Scene__VehicleWorld_can_land_, MRB_ARGS_REQ(3));
  mrb_define_method(M, vehicle_world, "hero_position",
                    RPG2k__Scene__VehicleWorld_hero_position, MRB_ARGS_NONE());
  mrb_define_method(M, vehicle_world, "set_switch",
                    RPG2k__Scene__VehicleWorld_set_switch, MRB_ARGS_REQ(2));
  mrb_define_method(M, vehicle_world, "random",
                    RPG2k__Scene__VehicleWorld_random, MRB_ARGS_REQ(1));
  // #play_sound is NOT registered here -- its own body ends in a real
  // `rescue StandardError => e` clause (EXCEPT/RESCUE/RAISEIF), the same
  // already-established out-of-scope shape as MapWorld's own identically-
  // shaped #play_sound.

  // RPG2k::Scene::EventResolver (same file, right below MapWorld/
  // VehicleWorld) -- the small helper that resolves a Call Event's own
  // command list, by common-event id (#common_event_commands) or by
  // map-event id/page (#map_event_commands). 2 of its own 3 real
  // bytecode-defined methods compile clean, needing no new opcode work at
  // all: #initialize (`initialize common_by_id, map_events`, pure
  // mandatory arity, no super, no block) and #common_event_commands (a
  // Hash#[] read/memoizing Hash#[]= write via GETIDX/SETIDX, plus one
  // real POLY `.event` send -- :event has other real definitions
  // elsewhere in the closed world, so it correctly stays ordinary
  // mrb_funcall dispatch, never devirtualized). #map_event_commands is
  // the one gap -- its own body ends in a real `rescue StandardError`
  // clause (RESCUE/RAISEIF/EXCEPT), the same already-established
  // out-of-scope shape as MapWorld's/VehicleWorld's own #play_sound
  // above. Neither of this class's own two ivars (@common, @map_events)
  // ever gets embedded: both are real Hashes, a type bc2cpp's embedding
  // lattice only ever models for Fixnum/Symbol. No bare `private`/
  // `protected` anywhere in the class body, so #common_event_commands is
  // `mrb_define_method`; #initialize itself is forced private by mruby's
  // own interpreter regardless of source, the same always-private
  // special case as every other compiled #initialize in this file.
  // Reuses the `scene` RClass* declared at the top of this function.
  RClass* event_resolver = mrb_class_get_under(M, scene, "EventResolver");
  mrb_define_private_method(M, event_resolver, "initialize",
                            RPG2k__Scene__EventResolver_initialize,
                            MRB_ARGS_REQ(2));
  mrb_define_method(M, event_resolver, "common_event_commands",
                    RPG2k__Scene__EventResolver_common_event_commands,
                    MRB_ARGS_REQ(1));
  // #map_event_commands is NOT registered here -- its own body ends in a
  // real `rescue StandardError` clause (RESCUE/RAISEIF/EXCEPT), the same
  // already-established out-of-scope shape as MapWorld's/VehicleWorld's
  // own #play_sound (see this file's own top comment).

  // Game::TextReveal (mruby-rpg2k/mrblib/game.rb) -- see this file's own
  // top comment for the real gap breakdown (#initialize's/#advance's own
  // non-mandatory arguments; #speed_at/#through_instant/#visible_lines'
  // own real Ruby blocks) and why no MRB_SET_INSTANCE_TT call belongs
  // here. No bare `private`/`protected`/`public` anywhere in the real
  // source, so every method below is `mrb_define_method`; #initialize
  // itself stays entirely interpreted (it never compiles), so it needs no
  // registration line at all. Reuses the `game` RClass* declared at the
  // top of this function.
  RClass* text_reveal = mrb_class_get_under(M, game, "TextReveal");
  mrb_define_method(M, text_reveal, "auto_close?", Game__TextReveal_auto_close_,
                    MRB_ARGS_NONE());
  mrb_define_method(M, text_reveal, "done?", Game__TextReveal_done_,
                    MRB_ARGS_NONE());
  mrb_define_method(M, text_reveal, "reveal_all", Game__TextReveal_reveal_all,
                    MRB_ARGS_NONE());
  mrb_define_method(M, text_reveal, "next_pause", Game__TextReveal_next_pause,
                    MRB_ARGS_NONE());
  mrb_define_method(M, text_reveal, "pending_pause",
                    Game__TextReveal_pending_pause, MRB_ARGS_NONE());
  mrb_define_method(M, text_reveal, "release_pause",
                    Game__TextReveal_release_pause, MRB_ARGS_NONE());

  // Game::NumberInput (mruby-rpg2k/mrblib/game.rb) -- the digit-cursor
  // input model backing the Input Number event command (a fixed count of
  // 0..9 digit cells, a movable cursor, per-cell increment/decrement, and
  // the entered base-10 integer). 6 of its own 7 real bytecode-defined
  // methods compile clean, needing no new opcode work at all:
  // #initialize, #digit, #inc, #dec, #left, #right (#digits/#cursor are
  // attr_reader-generated, native, invisible to bc2cpp the same way
  // every other attr_reader in this codebase is). #value is the one
  // gap -- its own body ends in a real `@values.each { |d| v = v * 10 +
  // d }` block (BLOCK/SENDB), the same established out-of-scope shape
  // every other block-using method above already documents. Neither of
  // this class's own two Fixnum-shaped ivars (@digits, @cursor) actually
  // gets embedded, despite #initialize having pure mandatory arity: both
  // are clamped/derived through a real conditional (`d = 1 if d < 1; d =
  // MAX_DIGITS if d > MAX_DIGITS`), and this compiler's ivar-type trace
  // resolves the last write ahead of each SETIV to the `d = MAX_DIGITS`
  // branch's own GETCONST (a constant lookup, never traced as a literal
  // fixnum value) -- both conservatively resolve to UNKNOWN and stay on
  // the ordinary dynamic iv_tbl. Safe (a missed embedding opportunity,
  // never an unsound one). @values (a real Array) gets a
  // devirtualization-only CLASS_HINT, never a struct-field candidate. No
  // bare `private`/`protected`/`public` anywhere in the real source, so
  // every method below is `mrb_define_method` except #initialize itself,
  // forced private by mruby's own interpreter regardless of source, the
  // same always-private special case as every other compiled #initialize
  // in this file. Reuses the `game` RClass* declared at the top of this
  // function.
  RClass* number_input = mrb_class_get_under(M, game, "NumberInput");
  mrb_define_private_method(M, number_input, "initialize",
                            Game__NumberInput_initialize, MRB_ARGS_REQ(1));
  mrb_define_method(M, number_input, "digit", Game__NumberInput_digit,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, number_input, "inc", Game__NumberInput_inc,
                    MRB_ARGS_NONE());
  mrb_define_method(M, number_input, "dec", Game__NumberInput_dec,
                    MRB_ARGS_NONE());
  mrb_define_method(M, number_input, "left", Game__NumberInput_left,
                    MRB_ARGS_NONE());
  mrb_define_method(M, number_input, "right", Game__NumberInput_right,
                    MRB_ARGS_NONE());
  // #value is NOT registered here -- its own body ends in a real
  // `@values.each { |d| ... }` block (BLOCK/SENDB), an already-established
  // out-of-scope shape (see this file's own top comment).

  // RPG2k::Scene::GameOver (mruby-rpg2k/mrblib/scene/game_over.rb) -- see
  // compiled_gems.rb's own comment on this gem's `owners:` entry for the
  // full writeup, including why the real source has 7 bytecode-defined
  // methods (not the 3 a first read of just #initialize/#update/#dispose
  // suggests) and why no MRB_SET_INSTANCE_TT call belongs here (its own
  // @picture ivar gets a devirtualization-only CLASS_HINT, Sprite, never
  // embedded, since #initialize never compiles). #update/#dispose are
  // `mrb_define_method`; #gameover_bgm_override/#database_gameover_bgm are
  // both `mrb_define_private_method` (a bare `private` mid-class-body, in
  // effect through the end of the class, confirmed directly against the
  // real source and flagged by bc2cpp's own diagnostic). #gameover_bitmap
  // and #play_gameover_bgm are NOT registered here -- each ends in a real
  // `rescue StandardError => e` clause (RESCUE/RAISEIF/EXCEPT), the same
  // already-established out-of-scope shape every other rescue-using method
  // in this file already documents. Reuses the `scene` RClass* declared at
  // the top of this function.
  RClass* game_over = mrb_class_get_under(M, scene, "GameOver");
  mrb_define_method(M, game_over, "update", RPG2k__Scene__GameOver_update,
                    MRB_ARGS_NONE());
  mrb_define_method(M, game_over, "dispose", RPG2k__Scene__GameOver_dispose,
                    MRB_ARGS_NONE());
  mrb_define_private_method(M, game_over, "gameover_bgm_override",
                            RPG2k__Scene__GameOver_gameover_bgm_override,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, game_over, "database_gameover_bgm",
                            RPG2k__Scene__GameOver_database_gameover_bgm,
                            MRB_ARGS_NONE());

  // Game::Actors (mruby-rpg2k/mrblib/game.rb) -- the actor-cache/lookup
  // container (plural, not Game::Actor itself, already a compiled owner
  // above): lazily builds and caches Game::Actor instances by database
  // id. #[] has a real `rescue RuntimeError => e` clause; #all ends in a
  // genuine Ruby block; #each takes an explicit `&blk` block parameter, a
  // non-mandatory-argument shape this compiler's calling convention
  // doesn't model at all -- none of the three are registered here. None
  // of this class's own three ivars (@db, @all, @missing) ever gets
  // embedded: @db is an opaque LCF::Database reference, and @all/
  // @missing are both real Hash literals, a type bc2cpp's embedding
  // lattice only ever models for Fixnum/Symbol. No bare `private`/
  // `protected`/`public` anywhere in the real source, so #existing and
  // #known_invalid? are both plain `mrb_define_method`; #initialize
  // itself is forced private by mruby's own interpreter regardless of
  // source. Reuses the `game` RClass* declared at the top of this
  // function.
  RClass* actors = mrb_class_get_under(M, game, "Actors");
  mrb_define_private_method(M, actors, "initialize", Game__Actors_initialize,
                            MRB_ARGS_REQ(1));
  mrb_define_method(M, actors, "existing", Game__Actors_existing,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, actors, "known_invalid?", Game__Actors_known_invalid_,
                    MRB_ARGS_REQ(1));
  // #[], #all, #each are NOT registered here: #[] has a real `rescue
  // RuntimeError` clause (RESCUE/RAISEIF/EXCEPT); #all ends in a genuine
  // Ruby block (BLOCK/SENDB); #each takes an explicit `&blk` block
  // parameter, a non-mandatory-argument shape this compiler's calling
  // convention doesn't model at all (see this block's own top comment).

  // Game::Rng (mruby-rpg2k/mrblib/game.rb) -- see compiled_gems.rb's own
  // comment on this gem's `owners:` entry for the full writeup. 3 of its
  // own 4 real bytecode-defined methods compile clean, needing no new
  // opcode work at all: #next_int (`@state = (@state * 75 + 74) %
  // PERIOD`, a real GETCONST plus MUL/ADDI fastpaths and a POLY `%` send
  // that correctly stays ordinary mrb_funcall dispatch -- `%` has other
  // real definitions project-wide, confirmed against the real generated
  // output showing no empty-name mrb_funcall shape), #random (a MONO
  // self-call straight into Game__Rng_next_int_impl, no mrb_funcall at
  // all -- :next_int has exactly one real bytecode definition anywhere in
  // the closed world) and #scaled (the same MONO self-call into
  // #next_int, plus a real DIV that correctly stays ordinary mrb_funcall
  // dispatch, per this compiler's own established no-fastpath-for-DIV
  // rule). #initialize (`initialize(seed = 1)`, one optional argument)
  // has the same established non-mandatory-arity gap as every other
  // unembedded target above, so drop_unsafe_embeddings correctly refuses
  // to embed this class's own one real ivar (@state, provably Fixnum) --
  // confirmed directly against the real generated output: Game::Rng does
  // not appear in bc2cpp's own "classes needing MRB_SET_INSTANCE_TT"
  // diagnostic, so no MRB_SET_INSTANCE_TT call belongs in its own
  // registration block, and @state stays on the ordinary dynamic
  // iv_tbl in every compiled method here. No bare `private`/`protected`/
  // `public` anywhere in the real source, so all three below are plain
  // `mrb_define_method`; #initialize itself is forced private by mruby's
  // own interpreter regardless of source, the same always-private special
  // case as every other compiled #initialize in this file.
  RClass* rng = mrb_class_get_under(M, game, "Rng");
  mrb_define_method(M, rng, "next_int", Game__Rng_next_int, MRB_ARGS_NONE());
  mrb_define_method(M, rng, "random", Game__Rng_random, MRB_ARGS_REQ(1));
  mrb_define_method(M, rng, "scaled", Game__Rng_scaled, MRB_ARGS_REQ(1));
  // #initialize is NOT registered here -- it takes one optional argument
  // (`seed = 1`), the same established non-mandatory-arity gap as every
  // other unembedded target above.

  // Game::Weather (mruby-rpg2k/mrblib/game.rb) -- the current
  // screen-weather effect state (rain/snow/fog/... type plus a 0-10
  // strength). #set/#none?/#to_h/#load_h all compile clean; #initialize
  // (two optional arguments) is NOT registered here -- it stays entirely
  // interpreted, the same established non-mandatory-arity gap as
  // Game::Picture's/RPG2k::Window's own #initialize above, and
  // drop_unsafe_embeddings correctly refuses to embed either of this
  // class's own two ivars (@type, @strength) as a result -- see this
  // file's own top comment and compiled_gems.rb's own owners-entry
  // comment for the full writeup. attr_reader :type, :strength are both
  // native (Module#attr_reader), invisible to bc2cpp the same way every
  // other attr_reader in this codebase is, so neither gets a registration
  // line here either. No bare `private`/`protected`/`public` anywhere in
  // the real source, so all four methods below are plain
  // `mrb_define_method`. Reuses the `game` RClass* declared at the top of
  // this function.
  RClass* weather = mrb_class_get_under(M, game, "Weather");
  mrb_define_method(M, weather, "set", Game__Weather_set, MRB_ARGS_REQ(2));
  mrb_define_method(M, weather, "none?", Game__Weather_none_, MRB_ARGS_NONE());
  mrb_define_method(M, weather, "to_h", Game__Weather_to_h, MRB_ARGS_NONE());
  mrb_define_method(M, weather, "load_h", Game__Weather_load_h,
                    MRB_ARGS_REQ(1));

  // Game::Troop (mruby-rpg2k/mrblib/game/battle_support.rb) -- see
  // compiled_gems.rb's own owners-entry comment for the full writeup.
  // Only #member (`def member(db, m); Enemy.new(db, m.enemy_id, m.x, m.y,
  // m.invisible); end`) compiles clean -- a plain 4-argument constructor
  // call, no arithmetic, no block. #initialize (`rng = nil`, one optional
  // argument) has the established non-mandatory-arity gap; #total_exp/
  // #total_gold (`live_members.reduce(0) { |s, e| s + e.<field> }`) and
  // #drops (`live_members.each_with_object([]) do |e, out| ... end`) each
  // end in a genuine Ruby block (BLOCK/SENDB); #live_members
  // (`@members.reject(&:hidden)`) hits the very same SENDB gap through a
  // different real shape -- `&:symbol` block-pass shorthand compiles to a
  // bare LOADSYM feeding SENDB directly, no BLOCK opcode at all (confirmed
  // against the real mrbc -v disassembly), so it is not a distinct opcode
  // gap, just SENDB reached a second way; #apply_appear_randomly ends in
  // two more real blocks (`@members.count { |m| ... }`,
  // `@members.each do |m| ... end`). #initialize never compiling means
  // drop_unsafe_embeddings correctly refuses to embed any of this class's
  // own ivars (@id/@name/@members/@pages) -- confirmed directly against
  // the real generated output: Game::Troop does not appear in bc2cpp's own
  // "classes needing MRB_SET_INSTANCE_TT" diagnostic, and #member's own
  // compiled body never touches DATA_PTR(self) at all (it is a pure
  // function of its two arguments, self is copied to a register and never
  // read again). #member is `private` (a bare `private` mid-class-body,
  // in effect through the end of the class, also covering #live_members/
  // #apply_appear_randomly above), so it needs
  // mrb_define_private_method, not mrb_define_method.
  RClass* troop = mrb_class_get_under(M, game, "Troop");
  mrb_define_private_method(M, troop, "member", Game__Troop_member,
                            MRB_ARGS_REQ(2));

  // Game::Vehicle (mruby-rpg2k/mrblib/game.rb) -- a boat/ship/airship's
  // saved location (map id, position, facing, on-map graphic), plain data
  // rather than a Game::Character. #placed?/#to_h/#load_h/#load_movable
  // all compile clean; #initialize (type, map_id = 0, x = 0, y = 0,
  // direction = 2 -- four optional arguments) is NOT registered here --
  // it stays entirely interpreted, the same established non-mandatory-
  // arity gap as Game::Picture's/RPG2k::Window's own #initialize above,
  // and drop_unsafe_embeddings correctly refuses to embed any of this
  // class's own four provably-Fixnum ivars (@map_id, @x, @y,
  // @charset_index) as a result -- see this file's own top comment and
  // compiled_gems.rb's own owners-entry comment for the full writeup.
  // attr_accessor :map_id, :x, :y, :direction, :charset_name,
  // :charset_index and attr_reader :type are all native
  // (Module#attr_reader/attr_accessor), invisible to bc2cpp the same way
  // every other attr_reader/writer/accessor in this codebase is, so none
  // of them gets a registration line here either. No bare `private`/
  // `protected`/`public` anywhere in the real source, so both methods
  // below are plain `mrb_define_method`. Reuses the `game` RClass*
  // declared at the top of this function.
  RClass* vehicle = mrb_class_get_under(M, game, "Vehicle");
  mrb_define_method(M, vehicle, "placed?", Game__Vehicle_placed_,
                    MRB_ARGS_NONE());
  mrb_define_method(M, vehicle, "to_h", Game__Vehicle_to_h, MRB_ARGS_NONE());
  mrb_define_method(M, vehicle, "load_h", Game__Vehicle_load_h,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, vehicle, "load_movable", Game__Vehicle_load_movable,
                    MRB_ARGS_REQ(1));

  // Game::Enemy (mruby-rpg2k/mrblib/game/battle_support.rb) -- see
  // compiled_gems.rb's own owners-entry comment for the full writeup. 3 of
  // its own 4 real bytecode-defined methods compile clean, needing zero
  // bc2cpp.rb changes: #attack_hit_rate (`@miss ? 70 : 90`, a plain GETIV
  // plus JMPIF-based ternary), #dead? (`@hp <= 0`, the fixnum-fastpath LE
  // this compiler already has), and #reseed_rewards (four plain SETIVs
  // fed by `into.exp`/`into.gold`/`into.drop_id`/`into.drop_prob`, each a
  // real POLY send that correctly stays ordinary mrb_funcall dispatch --
  // confirmed directly against the real generated output, not merely
  // assumed from the registry's own dump: see this class's own
  // compiled_gems.rb comment for why the registry's dump is misleadingly
  // stale for these four particular names, and why that staleness still
  // resolves safely here regardless). #initialize (`db, id, x = 0, y = 0,
  // hidden = false`, three optional arguments) is the one gap -- the same
  // established non-mandatory-arity shape as every other unembedded
  // target above, so drop_unsafe_embeddings correctly refuses to embed
  // any of this class's own thirteen provably-Fixnum ivars (@max_hp,
  // @max_sp, @atk, @def, @spi, @agi, @x, @y, @hp, @sp, @flying_phase,
  // @crit_chance, @battler_hue) despite the raw IvarLayout analysis
  // reporting all thirteen as EMBED-eligible -- confirmed directly
  // against the real generated output: Game::Enemy does not appear in
  // bc2cpp's own "classes needing MRB_SET_INSTANCE_TT" diagnostic, and
  // every compiled method here uses plain mrb_iv_get/mrb_iv_set, never
  // DATA_PTR(self). attr_reader :id, :name, :battler_name, :max_hp,
  // :max_sp, :atk, :def, :spi, :agi, :exp, :gold, :x, :y, :drop_id,
  // :drop_prob (one call, 15 names), attr_accessor :hp, :sp, :hidden,
  // and the smaller attr_reader :actions / :crit_chance,
  // :attribute_ranks, :state_ranks / :levitate / :transparent /
  // :battler_hue / attr_accessor :flying_phase are all native
  // (Module#attr_reader/attr_writer/attr_accessor), invisible to bc2cpp
  // the same way every other attr_reader/writer/accessor in this codebase
  // is, so none of them gets a registration line here either. No bare
  // `private`/`protected`/`public` anywhere in the real source, so all
  // three methods below are plain `mrb_define_method`. Reuses the `game`
  // RClass* declared at the top of this function.
  RClass* enemy = mrb_class_get_under(M, game, "Enemy");
  mrb_define_method(M, enemy, "attack_hit_rate", Game__Enemy_attack_hit_rate,
                    MRB_ARGS_NONE());
  mrb_define_method(M, enemy, "dead?", Game__Enemy_dead_, MRB_ARGS_NONE());
  mrb_define_method(M, enemy, "reseed_rewards", Game__Enemy_reseed_rewards,
                    MRB_ARGS_REQ(1));

  // RPG2k3::Scene::Battle (mruby-rpg2k/mrblib/scene/battle_rpg2k3.rb) -- the
  // real subclass (`class Battle < RPG2k::Scene::Battle`, a distinct
  // top-level namespace from RPG2k::Scene::* above, not the base UI battle
  // scene itself, which is not a compiled owner) adding RPG2003's
  // active-time-battle (ATB) gauge behavior. Has no #initialize of its own
  // (inherits the base class's), so there is no non-mandatory-arity gap to
  // worry about here -- but it also means none of its own ivar reads
  // (@state, @ui) can ever be an embedding concern regardless: embedding
  // only ever happens for a class whose OWN #initialize compiles with pure
  // mandatory arity, and confirmed directly against the real generated
  // output, this class never appears in bc2cpp's own "classes needing
  // MRB_SET_INSTANCE_TT" diagnostic (it never SETIVs at all in any of its
  // own methods -- every @ui/@state access here is a Hash #[]/#[]= read or
  // write, not a direct instance-variable assignment).
  //
  // 7 of its own 15 real bytecode-defined methods compile clean, needing no
  // new opcode work at all: #active_atb? (a MONO self-call into
  // #gauge_battle? plus an ivar read and a POLY `!=` compare),
  // #atb_accumulating? (a Hash #[] GETIDX read, a POLY `==`, a MONO
  // self-call into #active_atb?, and a POLY `Array#include?` send against
  // the frozen ATB_MENU_PHASES class-constant array literal),
  // #gauge_battle?, #drive_battle_atb (MONO self-calls into #controllable?
  // and #start_gauge_action, everything else POLY dynamic dispatch on
  // `battle`/self), #start_gauge_action, #enter_atb_phase (a MONO self-call
  // into #drive_battle_atb), and #controllable?. The other 8 all stay on
  // the interpreter: #update, #drive_battle_command, #enter_command_phase,
  // #open_battle_options, #advance_actor, and #prev_commandable_actor_index
  // each end in (or, for #update, has one branch reach) a bare `super` --
  // OP_SUPER, out of this compiler's opcode scope, the same established gap
  // RPG2k::Scene::ItemMenu's/DebugMenu's own #initialize already document.
  // #finish_round_animation also calls `super` (conditionally) on top of
  // several genuine Ruby blocks (`select(&:defending)`,
  // `select(&:dead?)`, `.uniq { |a| ... }`, `.each { |ally| ... }` --
  // BLOCK/SENDB), and #interrupting_ready_combatant ends in one more real
  // block (`ready_combatants.find { |c| ... }`) -- the same established
  // out-of-scope shape every other block-using method in this file already
  // documents. No bare `private`/`protected`/`public` anywhere in the real
  // source, so all 7 registered methods below are plain `mrb_define_method`
  // -- confirmed directly against the real diagnostic's own
  // `== compiled entry points ==` listing, none flagged `[private]`/
  // `[protected]`. RPG2k3 is a distinct top-level namespace from RPG2k
  // (not nested under it), so it needs its own fresh mrb_module_get/
  // mrb_module_get_under chain rather than reusing the `rpg2k`/`scene`
  // locals declared above for RPG2k::Scene::* -- otherwise this is exactly
  // the same mrb_class_get_under shape every RPG2k::Scene::X registration
  // above already uses; mrbgems dependency order still guarantees
  // mruby-rpg2k's own gem init (which defines RPG2k3::Scene::Battle, in
  // the same gem) has already fully run by the time this gem's own init
  // starts.
  RClass* rpg2k3 = mrb_module_get(M, "RPG2k3");
  RClass* rpg2k3_scene = mrb_module_get_under(M, rpg2k3, "Scene");
  RClass* battle_2k3 = mrb_class_get_under(M, rpg2k3_scene, "Battle");
  mrb_define_method(M, battle_2k3, "active_atb?",
                    RPG2k3__Scene__Battle_active_atb_, MRB_ARGS_NONE());
  mrb_define_method(M, battle_2k3, "atb_accumulating?",
                    RPG2k3__Scene__Battle_atb_accumulating_, MRB_ARGS_NONE());
  mrb_define_method(M, battle_2k3, "gauge_battle?",
                    RPG2k3__Scene__Battle_gauge_battle_, MRB_ARGS_NONE());
  mrb_define_method(M, battle_2k3, "drive_battle_atb",
                    RPG2k3__Scene__Battle_drive_battle_atb, MRB_ARGS_NONE());
  mrb_define_method(M, battle_2k3, "start_gauge_action",
                    RPG2k3__Scene__Battle_start_gauge_action, MRB_ARGS_REQ(1));
  mrb_define_method(M, battle_2k3, "enter_atb_phase",
                    RPG2k3__Scene__Battle_enter_atb_phase, MRB_ARGS_NONE());
  mrb_define_method(M, battle_2k3, "controllable?",
                    RPG2k3__Scene__Battle_controllable_, MRB_ARGS_REQ(1));

  // Game::MessageConfig (mruby-rpg2k/mrblib/game.rb) -- Message Options
  // settings (window transparency, text position, face-graphic selection).
  // A deliberate stress-test of the eighth severe bug's own fix
  // (`natively_exposed?`) and its ninth-round follow-up (the stale
  // `LCF::MoveCommand` MRB_SET_INSTANCE_TT tag), since every one of this
  // class's own 8 ivars is covered by a plain `attr_accessor` -- see
  // compiled_gems.rb's own owners-entry comment for the full per-ivar
  // writeup. #initialize compiles clean (arity 0), and its own
  // provably-Fixnum ivar (@face_index) genuinely reaches bc2cpp's own
  // ivar-embedding proposal pass (`EMBED Game::MessageConfig#@face_index
  // (fixnum)` in the real diagnostic) but is then correctly vetoed by
  // `natively_exposed?` because of `attr_accessor :face_index` -- confirmed
  // directly against the real regenerated output: this class does **not**
  // appear in bc2cpp's own "classes needing MRB_SET_INSTANCE_TT(...,
  // MRB_TT_DATA)" diagnostic, so no MRB_SET_INSTANCE_TT call belongs here,
  // and every ivar write below (initialize/clear_face) goes through plain
  // mrb_iv_set, never DATA_PTR(self)/mrb_data_init. (@position, the other
  // ivar that looks Fixnum-shaped, is assigned from a GETCONST-fed
  // constant, not a literal, so IvarLayout never even proposes it as an
  // embedding candidate in the first place -- a distinct, independent
  // reason from @face_index's, the same two-reasons-at-once shape this
  // file's own `LCF::Tree` follow-up already documents for a sibling gem.)
  //
  // 4 of its own 5 real bytecode-defined methods compile clean:
  // #initialize, #face? (`!@face_name.nil? && !@face_name.empty?`),
  // #clear_face (four plain SETIVs), and #to_h (a literal Hash of all 8
  // ivars). #load_h is the one gap, and a genuinely new one for
  // this compiler: both its early-exit `return self unless h` and its own
  // trailing bare `self` disassemble to RETSELF (mrbc's own dedicated
  // opcode for returning `self` specifically, distinct from
  // RETURN/RETNIL/RETFALSE/RETTRUE), and compile_insn has no `when
  // 'RETSELF'` case at all -- confirmed by grepping bc2cpp.rb (zero hits)
  // and by disassembling this exact method with the real host `mrbc -v`.
  // Safe either way, by this compiler's own established discipline
  // (SKIP_UNSUPPORTED=1 just leaves the whole method on the interpreter);
  // the other four classes sharing the `:load_h` name (Game::Screen,
  // Game::Weather, Game::Vehicle, Game::Timer) all use a bare `return
  // unless h` with no explicit value -- RETNIL, not RETSELF -- so all four
  // still compile and appear in the real `== compiled entry points ==`
  // listing; this class's own `#load_h` does not. Not fixed here (no new
  // bc2cpp.rb opcode work) since nothing here needs it to ship -- left as a
  // real, confirmed-safe structural gap for a future round.
  //
  // Like every other embedding-attempted #initialize above,
  // mrb_define_private_method for #initialize (Ruby's own implicit
  // #initialize privacy -- confirmed live in the real diagnostic's own
  // `== compiled entry points ==` listing: `[private -- use
  // mrb_define_private_method, not mrb_define_method]`). No bare
  // `private`/`protected`/`public` anywhere in the real source beyond that,
  // so the other 2 registered methods below are plain `mrb_define_method`.
  // Reuses the `game` RClass* declared at the top of this function.
  RClass* message_config = mrb_class_get_under(M, game, "MessageConfig");
  mrb_define_private_method(M, message_config, "initialize",
                            Game__MessageConfig_initialize, MRB_ARGS_NONE());
  mrb_define_method(M, message_config, "face?", Game__MessageConfig_face_,
                    MRB_ARGS_NONE());
  mrb_define_method(M, message_config, "clear_face",
                    Game__MessageConfig_clear_face, MRB_ARGS_NONE());
  mrb_define_method(M, message_config, "to_h", Game__MessageConfig_to_h,
                    MRB_ARGS_NONE());

  // Game::Interpreter (docs/adr/0139's own follow-up, mruby-rpg2k/mrblib/
  // interpreter.rb, plus a separate 4-method reopening in mruby-rpg2k/
  // mrblib/game/battle_support.rb) -- the RPG2000 event-command
  // interpreter: runs a decoded LCF::EventCommand list against Game::State,
  // applying state-only commands (switches/variables/party/gold/items/
  // conditional branches) directly and recording a request (then pausing)
  // for anything that needs the UI or the map. Already a registry-visible
  // owner before this round (`bc2cpp`'s own whole-program registry walk
  // always covers every gem's mrblib regardless of any single compiled
  // gem's own `owners:` list -- see tools/bc2cpp/compiled_gems.rb's own
  // `closed_world_mrblib_srcs` comment), used for MONO/POLY
  // devirtualization soundness elsewhere in this file long before any of
  // its own methods were ever emitted -- this round adds it as a real
  // emission owner for the first time. By far the largest class in this
  // gem by real method count: 207 real bytecode-defined methods (203 in
  // interpreter.rb + 4 in the battle_support.rb reopening,
  // #take_revealed_monsters/#take_fled_monsters/#take_monster_kills/
  // #take_battle_background), legitimately too large to fully cover in one
  // round -- 173 compile clean and are registered below; the other 34 stay
  // on the interpreter, all for real, individually confirmed gaps (none
  // guessed from a shared shape), never a silent drop:
  //
  //   - 20 end in a real Ruby block (BLOCK/SENDB): #restore_call_stack,
  //     #resume_inn, #key_input_result, #do_jump_label,
  //     #do_control_switches, #do_control_vars,
  //     #do_control_vars_range_variable, #do_change_exp, #do_change_level,
  //     #queue_level_up_messages, #do_change_hp, #do_change_mp,
  //     #do_full_heal, #do_simulated_attack, #do_change_condition,
  //     #do_change_class, #do_change_battle_commands, #do_change_params,
  //     #do_change_skills, #do_change_equipment -- every one of these
  //     iterates a party/target list (`actors.each`, `targets.each`, ...),
  //     the same already-established out-of-scope shape as every other
  //     BLOCK/SENDB gap in this file.
  //   - 8 end in a real `rescue StandardError` clause (EXCEPT/RESCUE/
  //     RAISEIF): #resolve_call, #do_call_common_event,
  //     #common_event_commands, #do_store_terrain_id, #do_store_event_id,
  //     #do_fadeout_bgm, #do_play_memorized_bgm, #play_audio -- the same
  //     already-established out-of-scope shape as MapWorld's/
  //     VehicleWorld's own #play_sound.
  //   - 3 hit a real, still-unmodeled opcode this compiler has never had a
  //     `when` case for at all: #update, #skip_to, #do_show_choices all
  //     emit `#error unhandled opcode JMPUW` -- confirmed directly against
  //     3rd/mruby/src/vm.c's own `OP_JMPUW` (`unwind_and_jump_to`, per its
  //     own ops.h comment): a jump that has to unwind through an active
  //     `ensure`/break catch-handler region on its way to the target,
  //     mrbc's own compiled shape for a `break`/early-`return` reachable
  //     from inside one of these methods' own `until`/loop bodies. Left
  //     unfixed (no new bc2cpp.rb opcode work this round) -- a real,
  //     confirmed-safe structural gap for a future round, the same
  //     discipline this file's own RETSELF/Game::MessageConfig#load_h
  //     writeup already established for a different never-modeled opcode.
  //   - 2 send a keyword-argument-heavy call this compiler's own
  //     `compile_send` already refuses on sight (a splat/keyword argument
  //     list, not a plain positional one): #do_show_picture
  //     (`.show_picture` with 11 keyword arguments, confirmed via the real
  //     marker `SEND/SSEND :show_picture has a splat and/or keyword
  //     argument list (n=1|nk=11)`) and #do_change_parallax
  //     (`.set_parallax` with 7 keyword arguments, `n=0|nk=7`) -- the same
  //     already-established out-of-scope shape this ADR's own third-
  //     severe-bug follow-up (the silently-dropped-keyword-argument fix)
  //     documents at the root.
  //   - 1 has a real optional argument: #start_random_battle -- the same
  //     already-established non-mandatory-arity gap as every other
  //     interpreted #initialize in this codebase.
  //
  // #initialize(state) has pure mandatory arity (1 argument) and compiles
  // clean, so drop_unsafe_embeddings does NOT refuse this class outright --
  // but it ends up with ZERO real embedded ivars, not from any attr_reader/
  // writer/accessor collision (this class has none), but from this same
  // round's own generalized `every_accessor_compiles?` fix (tools/bc2cpp/
  // bc2cpp.rb): the raw IvarLayout analysis proposes exactly one candidate,
  // @frame_steps (a provably-Fixnum this-frame step budget, set in
  // #initialize/#reset_frame_steps and read/incremented in #update's own
  // `break if @frame_steps >= MAX_STEPS` / `@frame_steps +=
  // step_cost(cmd.code)`) -- but #update is one of the 3 JMPUW gaps above,
  // so it never compiles, and every_accessor_compiles? correctly refuses
  // to embed @frame_steps rather than let a real 4th severe bug ship (a
  // compiled #initialize/#reset_frame_steps writing a real Fixnum struct
  // field while #update's own still-interpreted body reads/writes the
  // exact same ivar name through the ordinary, never-populated `iv_tbl`
  // instead -- see this round's own bc2cpp.rb fix and its Game::Transition
  // writeup above for the first real, live instance of this exact bug
  // class this same fix independently found and closed). No
  // MRB_SET_INSTANCE_TT call belongs here as a result -- confirmed
  // directly against the real, current whole-program diagnostic's own
  // "classes needing MRB_SET_INSTANCE_TT" list, which does not name
  // Game::Interpreter.
  //
  // Visibility: a bare `private` (mruby-rpg2k/mrblib/interpreter.rb) sits
  // partway through the class body and stays in effect through the end of
  // it, *except* two names explicitly reopened with `public :name`
  // immediately afterward (`public :start_random_battle`, `public
  // :start_death_handler`) -- #start_random_battle never compiles anyway
  // (see above), but #start_death_handler does, and the real diagnostic
  // confirms it correctly carries no `[private -- ...]` tag, unlike every
  // other method below it in source order; registered with plain
  // `mrb_define_method`, not `mrb_define_private_method`, below.
  // #initialize itself is *also* always private, the same real interpreter
  // special case (mruby's own src/class.c forces it unconditionally at
  // `def`-time) as every other compiled #initialize in this file, not from
  // the bare `private` above (which sits well after #initialize's own
  // `def`). Every visibility marking below was cross-checked against the
  // real `== compiled entry points ==` diagnostic output directly, not
  // inferred from source position alone.
  //
  // Real MONO/POLY registry soundness, checked and confirmed correct, not
  // just assumed sound because it compiled: #party/#switches/#variables
  // (all three private, all three a bare `@state.x`) share their own bare
  // name with Game::State's own public `attr_reader :party, :switches,
  // ... :variables` -- exactly the same collision shape this ADR's own
  // third-severe-bug follow-up fixed at the registry level
  // (`attr_reader`/`writer`/`accessor` sends now register a synthetic,
  // irep-nil MethodDef). Confirmed live and correctly conservative in the
  // real current registry dump: `:party`/`:switches`/`:variables` all show
  // POLY (2 defs: Game::State, Game::Interpreter) now that this class is a
  // real owner, so every real call site sending any of these three names
  // anywhere in the whole closed world still goes through ordinary
  // `mrb_funcall` dynamic dispatch -- never a direct call into the wrong
  // class's own `_impl`, the same live infinite-recursion shape a prior
  // follow-up already found and confirmed NOT live for this exact
  // `Game::Interpreter#switches`/`Game::State#switches` pair, back when
  // Game::Interpreter was registry-visible but not yet a compiled owner.
  //
  // Reuses the `game` RClass* declared at the top of this function.
  RClass* interpreter = mrb_class_get_under(M, game, "Interpreter");
  mrb_define_private_method(M, interpreter, "initialize",
                            Game__Interpreter_initialize, MRB_ARGS_REQ(1));
  mrb_define_method(M, interpreter, "finished?", Game__Interpreter_finished_,
                    MRB_ARGS_NONE());
  mrb_define_private_method(M, interpreter, "set_switch",
                            Game__Interpreter_set_switch, MRB_ARGS_REQ(2));
  mrb_define_method(M, interpreter, "take_revealed_monsters",
                    Game__Interpreter_take_revealed_monsters, MRB_ARGS_NONE());
  mrb_define_method(M, interpreter, "take_fled_monsters",
                    Game__Interpreter_take_fled_monsters, MRB_ARGS_NONE());
  mrb_define_method(M, interpreter, "take_monster_kills",
                    Game__Interpreter_take_monster_kills, MRB_ARGS_NONE());
  mrb_define_method(M, interpreter, "take_battle_background",
                    Game__Interpreter_take_battle_background, MRB_ARGS_NONE());
  mrb_define_private_method(M, interpreter, "trans_to_opacity",
                            Game__Interpreter_trans_to_opacity,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "execute",
                            Game__Interpreter_execute, MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "compare",
                            Game__Interpreter_compare, MRB_ARGS_REQ(3));
  mrb_define_method(M, interpreter, "start", Game__Interpreter_start,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, interpreter, "stop", Game__Interpreter_stop,
                    MRB_ARGS_NONE());
  mrb_define_private_method(M, interpreter, "party", Game__Interpreter_party,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, interpreter, "switches",
                            Game__Interpreter_switches, MRB_ARGS_NONE());
  mrb_define_private_method(M, interpreter, "variables",
                            Game__Interpreter_variables, MRB_ARGS_NONE());
  mrb_define_method(M, interpreter, "running?", Game__Interpreter_running_,
                    MRB_ARGS_NONE());
  mrb_define_method(M, interpreter, "waiting?", Game__Interpreter_waiting_,
                    MRB_ARGS_NONE());
  mrb_define_method(M, interpreter, "take_move_route_requests",
                    Game__Interpreter_take_move_route_requests,
                    MRB_ARGS_NONE());
  mrb_define_method(M, interpreter, "take_location_requests",
                    Game__Interpreter_take_location_requests, MRB_ARGS_NONE());
  mrb_define_method(M, interpreter, "take_erase_request",
                    Game__Interpreter_take_erase_request, MRB_ARGS_NONE());
  mrb_define_method(M, interpreter, "take_tileset_request",
                    Game__Interpreter_take_tileset_request, MRB_ARGS_NONE());
  mrb_define_method(M, interpreter, "take_parallax_request",
                    Game__Interpreter_take_parallax_request, MRB_ARGS_NONE());
  mrb_define_method(M, interpreter, "take_halt_movement_request",
                    Game__Interpreter_take_halt_movement_request,
                    MRB_ARGS_NONE());
  mrb_define_method(M, interpreter, "take_actor_graphic_changed",
                    Game__Interpreter_take_actor_graphic_changed,
                    MRB_ARGS_NONE());
  mrb_define_method(M, interpreter, "take_system_graphic_changed",
                    Game__Interpreter_take_system_graphic_changed,
                    MRB_ARGS_NONE());
  mrb_define_method(M, interpreter, "take_tiles_changed",
                    Game__Interpreter_take_tiles_changed, MRB_ARGS_NONE());
  mrb_define_method(M, interpreter, "take_vehicle_toggle_request",
                    Game__Interpreter_take_vehicle_toggle_request,
                    MRB_ARGS_NONE());
  mrb_define_method(M, interpreter, "take_movie_request",
                    Game__Interpreter_take_movie_request, MRB_ARGS_NONE());
  mrb_define_method(M, interpreter, "take_sprite_flash_requests",
                    Game__Interpreter_take_sprite_flash_requests,
                    MRB_ARGS_NONE());
  mrb_define_method(M, interpreter, "take_battle_animation_request",
                    Game__Interpreter_take_battle_animation_request,
                    MRB_ARGS_NONE());
  mrb_define_method(M, interpreter, "reset_frame_steps",
                    Game__Interpreter_reset_frame_steps, MRB_ARGS_NONE());
  mrb_define_method(M, interpreter, "step_cost", Game__Interpreter_step_cost,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, interpreter, "return_from_call",
                    Game__Interpreter_return_from_call, MRB_ARGS_NONE());
  mrb_define_method(M, interpreter, "resumable_index",
                    Game__Interpreter_resumable_index, MRB_ARGS_NONE());
  mrb_define_method(M, interpreter, "diagnostic_position",
                    Game__Interpreter_diagnostic_position, MRB_ARGS_NONE());
  mrb_define_method(M, interpreter, "call_stack_snapshot",
                    Game__Interpreter_call_stack_snapshot, MRB_ARGS_NONE());
  mrb_define_method(M, interpreter, "start_at", Game__Interpreter_start_at,
                    MRB_ARGS_REQ(2));
  mrb_define_method(M, interpreter, "resume", Game__Interpreter_resume,
                    MRB_ARGS_NONE());
  mrb_define_method(M, interpreter, "choose", Game__Interpreter_choose,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, interpreter, "choice_cancellable?",
                    Game__Interpreter_choice_cancellable_, MRB_ARGS_NONE());
  mrb_define_method(M, interpreter, "cancel_choice",
                    Game__Interpreter_cancel_choice, MRB_ARGS_NONE());
  mrb_define_method(M, interpreter, "resume_number",
                    Game__Interpreter_resume_number, MRB_ARGS_REQ(1));
  mrb_define_method(M, interpreter, "resume_name_input",
                    Game__Interpreter_resume_name_input, MRB_ARGS_REQ(1));
  mrb_define_method(M, interpreter, "resume_key_input",
                    Game__Interpreter_resume_key_input, MRB_ARGS_REQ(1));
  mrb_define_method(M, interpreter, "find_inn_option",
                    Game__Interpreter_find_inn_option, MRB_ARGS_REQ(1));
  mrb_define_method(M, interpreter, "resume_shop",
                    Game__Interpreter_resume_shop, MRB_ARGS_REQ(1));
  mrb_define_method(M, interpreter, "find_shop_option",
                    Game__Interpreter_find_shop_option, MRB_ARGS_REQ(1));
  mrb_define_method(M, interpreter, "resume_battle",
                    Game__Interpreter_resume_battle, MRB_ARGS_REQ(1));
  mrb_define_method(M, interpreter, "find_battle_option",
                    Game__Interpreter_find_battle_option, MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "reset_waits",
                            Game__Interpreter_reset_waits, MRB_ARGS_NONE());
  mrb_define_private_method(M, interpreter, "do_call_event",
                            Game__Interpreter_do_call_event, MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "map_event_call",
                            Game__Interpreter_map_event_call, MRB_ARGS_REQ(2));
  mrb_define_private_method(M, interpreter, "character_ref",
                            Game__Interpreter_character_ref, MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "consume",
                            Game__Interpreter_consume, MRB_ARGS_NONE());
  mrb_define_private_method(M, interpreter, "do_end_loop",
                            Game__Interpreter_do_end_loop, MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "do_break_loop",
                            Game__Interpreter_do_break_loop, MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "do_show_message",
                            Game__Interpreter_do_show_message, MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "do_message_options",
                            Game__Interpreter_do_message_options,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "do_change_face",
                            Game__Interpreter_do_change_face, MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "find_choice_option",
                            Game__Interpreter_find_choice_option,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "do_input_number",
                            Game__Interpreter_do_input_number, MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "do_key_input",
                            Game__Interpreter_do_key_input, MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "do_name_input",
                            Game__Interpreter_do_name_input, MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "do_show_inn",
                            Game__Interpreter_do_show_inn, MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "do_open_shop",
                            Game__Interpreter_do_open_shop, MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "do_enemy_encounter",
                            Game__Interpreter_do_enemy_encounter,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "skip_invalid_troop",
                            Game__Interpreter_skip_invalid_troop,
                            MRB_ARGS_REQ(1));
  mrb_define_method(M, interpreter, "start_death_handler",
                    Game__Interpreter_start_death_handler, MRB_ARGS_NONE());
  mrb_define_private_method(M, interpreter, "range", Game__Interpreter_range,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "operand_value",
                            Game__Interpreter_operand_value, MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "event_operand",
                            Game__Interpreter_event_operand, MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "vehicle_operand",
                            Game__Interpreter_vehicle_operand, MRB_ARGS_REQ(2));
  mrb_define_private_method(M, interpreter, "screen_operand",
                            Game__Interpreter_screen_operand, MRB_ARGS_REQ(2));
  mrb_define_private_method(M, interpreter, "item_operand",
                            Game__Interpreter_item_operand, MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "random_operand",
                            Game__Interpreter_random_operand, MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "actor_operand",
                            Game__Interpreter_actor_operand, MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "enemy_operand",
                            Game__Interpreter_enemy_operand, MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "other_operand",
                            Game__Interpreter_other_operand, MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "apply", Game__Interpreter_apply,
                            MRB_ARGS_REQ(3));
  mrb_define_private_method(M, interpreter, "trunc_div",
                            Game__Interpreter_trunc_div, MRB_ARGS_REQ(2));
  mrb_define_private_method(M, interpreter, "trunc_mod",
                            Game__Interpreter_trunc_mod, MRB_ARGS_REQ(2));
  mrb_define_private_method(M, interpreter, "do_timer",
                            Game__Interpreter_do_timer, MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "do_change_gold",
                            Game__Interpreter_do_change_gold, MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "do_change_items",
                            Game__Interpreter_do_change_items, MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "do_change_party",
                            Game__Interpreter_do_change_party, MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "check_game_over",
                            Game__Interpreter_check_game_over, MRB_ARGS_NONE());
  mrb_define_private_method(M, interpreter, "level_up_message",
                            Game__Interpreter_level_up_message,
                            MRB_ARGS_REQ(2));
  mrb_define_private_method(M, interpreter, "skill_learned_message",
                            Game__Interpreter_skill_learned_message,
                            MRB_ARGS_REQ(2));
  mrb_define_private_method(M, interpreter, "party_term",
                            Game__Interpreter_party_term, MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "show_next_pending_message",
                            Game__Interpreter_show_next_pending_message,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, interpreter, "stat_targets",
                            Game__Interpreter_stat_targets, MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "stat_amount",
                            Game__Interpreter_stat_amount, MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "simulated_attack_variance",
                            Game__Interpreter_simulated_attack_variance,
                            MRB_ARGS_REQ(2));
  mrb_define_private_method(M, interpreter, "identity_target",
                            Game__Interpreter_identity_target, MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "do_change_actor_name",
                            Game__Interpreter_do_change_actor_name,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "do_change_actor_title",
                            Game__Interpreter_do_change_actor_title,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "do_change_actor_sprite",
                            Game__Interpreter_do_change_actor_sprite,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "do_change_actor_face",
                            Game__Interpreter_do_change_actor_face,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "vehicle_target",
                            Game__Interpreter_vehicle_target, MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "do_set_vehicle_location",
                            Game__Interpreter_do_set_vehicle_location,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "do_change_vehicle_graphic",
                            Game__Interpreter_do_change_vehicle_graphic,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "monster_change_amount",
                            Game__Interpreter_monster_change_amount,
                            MRB_ARGS_REQ(2));
  mrb_define_private_method(M, interpreter, "do_change_monster_hp",
                            Game__Interpreter_do_change_monster_hp,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "do_change_monster_mp",
                            Game__Interpreter_do_change_monster_mp,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "do_change_monster_condition",
                            Game__Interpreter_do_change_monster_condition,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "do_show_hidden_monster",
                            Game__Interpreter_do_show_hidden_monster,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "do_force_flee",
                            Game__Interpreter_do_force_flee, MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "do_enable_combo",
                            Game__Interpreter_do_enable_combo, MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "do_change_battle_bg",
                            Game__Interpreter_do_change_battle_bg,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "do_show_battle_animation_b",
                            Game__Interpreter_do_show_battle_animation_b,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "do_terminate_battle",
                            Game__Interpreter_do_terminate_battle,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "do_conditional_battle",
                            Game__Interpreter_do_conditional_battle,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "eval_battle_condition",
                            Game__Interpreter_eval_battle_condition,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "battle_actor_condition",
                            Game__Interpreter_battle_actor_condition,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "battle_enemy_condition",
                            Game__Interpreter_battle_enemy_condition,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "battle_command_condition",
                            Game__Interpreter_battle_command_condition,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "battle_target_enemy_condition",
                            Game__Interpreter_battle_target_enemy_condition,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "do_conditional",
                            Game__Interpreter_do_conditional, MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "eval_condition",
                            Game__Interpreter_eval_condition, MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "timer_condition",
                            Game__Interpreter_timer_condition, MRB_ARGS_REQ(2));
  mrb_define_private_method(M, interpreter, "character_facing",
                            Game__Interpreter_character_facing,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "actor_condition",
                            Game__Interpreter_actor_condition, MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "do_teleport",
                            Game__Interpreter_do_teleport, MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "teleport_facing",
                            Game__Interpreter_teleport_facing, MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "do_memorize_location",
                            Game__Interpreter_do_memorize_location,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "do_recall_location",
                            Game__Interpreter_do_recall_location,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "do_change_event_location",
                            Game__Interpreter_do_change_event_location,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "do_trade_event_locations",
                            Game__Interpreter_do_trade_event_locations,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "query_position",
                            Game__Interpreter_query_position, MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "do_move_event",
                            Game__Interpreter_do_move_event, MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "decode_move_route",
                            Game__Interpreter_decode_move_route,
                            MRB_ARGS_REQ(2));
  mrb_define_private_method(M, interpreter, "do_wait",
                            Game__Interpreter_do_wait, MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "do_proceed_with_movement",
                            Game__Interpreter_do_proceed_with_movement,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "do_player_visibility",
                            Game__Interpreter_do_player_visibility,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "do_flash_sprite",
                            Game__Interpreter_do_flash_sprite, MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "do_open_save_menu",
                            Game__Interpreter_do_open_save_menu,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "do_open_main_menu",
                            Game__Interpreter_do_open_main_menu,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "do_tile_substitution",
                            Game__Interpreter_do_tile_substitution,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "do_return_to_title",
                            Game__Interpreter_do_return_to_title,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "do_open_load_menu",
                            Game__Interpreter_do_open_load_menu,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "do_exit_game",
                            Game__Interpreter_do_exit_game, MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "do_toggle_atb_mode",
                            Game__Interpreter_do_toggle_atb_mode,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "do_toggle_fullscreen",
                            Game__Interpreter_do_toggle_fullscreen,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "do_open_video_options",
                            Game__Interpreter_do_open_video_options,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "do_game_over",
                            Game__Interpreter_do_game_over, MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "do_erase_screen",
                            Game__Interpreter_do_erase_screen, MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "do_show_screen",
                            Game__Interpreter_do_show_screen, MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "teleport_transition",
                            Game__Interpreter_teleport_transition,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "do_tint_screen",
                            Game__Interpreter_do_tint_screen, MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "do_flash_screen",
                            Game__Interpreter_do_flash_screen, MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "do_pan_screen",
                            Game__Interpreter_do_pan_screen, MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "do_shake_screen",
                            Game__Interpreter_do_shake_screen, MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "message_window_blocks_command?",
                            Game__Interpreter_message_window_blocks_command_,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, interpreter, "block_pending_picture_command",
                            Game__Interpreter_block_pending_picture_command,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, interpreter, "block_pending_teleport_command",
                            Game__Interpreter_block_pending_teleport_command,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, interpreter, "block_pending_screen_command",
                            Game__Interpreter_block_pending_screen_command,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, interpreter, "block_pending_battle_command",
                            Game__Interpreter_block_pending_battle_command,
                            MRB_ARGS_NONE());
  mrb_define_private_method(M, interpreter, "block_pending_exp_level_command",
                            Game__Interpreter_block_pending_exp_level_command,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "block_pending_key_input_command",
                            Game__Interpreter_block_pending_key_input_command,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(
      M, interpreter, "block_pending_message_config_command",
      Game__Interpreter_block_pending_message_config_command, MRB_ARGS_NONE());
  mrb_define_private_method(M, interpreter, "do_move_picture",
                            Game__Interpreter_do_move_picture, MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "do_erase_picture",
                            Game__Interpreter_do_erase_picture,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "do_show_battle_animation",
                            Game__Interpreter_do_show_battle_animation,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "picture_coord",
                            Game__Interpreter_picture_coord, MRB_ARGS_REQ(2));
  mrb_define_private_method(M, interpreter, "picture_name",
                            Game__Interpreter_picture_name, MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "do_weather",
                            Game__Interpreter_do_weather, MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "do_play_movie",
                            Game__Interpreter_do_play_movie, MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "do_memorize_bgm",
                            Game__Interpreter_do_memorize_bgm, MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "do_set_teleport_target",
                            Game__Interpreter_do_set_teleport_target,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "do_set_escape_target",
                            Game__Interpreter_do_set_escape_target,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "do_change_system_graphic",
                            Game__Interpreter_do_change_system_graphic,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "do_change_system_bgm",
                            Game__Interpreter_do_change_system_bgm,
                            MRB_ARGS_REQ(1));
  mrb_define_private_method(M, interpreter, "do_change_system_sfx",
                            Game__Interpreter_do_change_system_sfx,
                            MRB_ARGS_REQ(1));
}

extern "C" void mrb_mruby_rpg2k_compiled_gem_final(mrb_state*) {}
