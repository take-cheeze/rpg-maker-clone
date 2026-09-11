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
// set_faceset, restore_class, ...) were generated with DATA_PTR(self)
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
// 5 more methods project-wide (none in any already-shipped owner set).
// mruby-rpg2k (this gem's own add_dependency) has already run its full gem
// init -- C hook *and* mrblib -- by the time this gem's own init runs
// (mrbgems.rake sequences gem_funcs[] in dependency order, each entry
// running its complete init before the next gem's own init starts), so
// all eight classes are guaranteed to already exist below.
//
// Game::Picture's own 11 real embeddable ivars (@x, @y, @show_x, @show_y,
// @zoom, @opacity, @red, @green, @blue, @saturation, @frames -- all
// provably Fixnum, per bc2cpp's whole-program analysis) are deliberately
// NOT embedded into an RData struct here: that would need the struct
// allocated in #initialize (mrb_data_init), and #initialize itself can't
// be compiled -- bc2cpp's own drop_unsafe_embeddings guard already refuses
// to emit embedded-struct GETIV/SETIV for exactly this reason (see its own
// comment), so every ivar access below still goes through the ordinary
// dynamic iv_tbl (ivar_layout stays a lookup keyed off the *ivar_layout*
// bc2cpp exports, safe by construction) -- no MRB_SET_INSTANCE_TT call
// needed here, unlike Game::Screen's own block below. RPG2k::Window is
// exactly the same shape: 7 real provably-Fixnum ivars (@x, @y, @width,
// @height, @cursor_frame, @arrow_anim, @anim_frames_left) that bc2cpp's
// own whole-program analysis reports as embeddable, but its own
// #initialize can't compile either (four optional arguments), so
// drop_unsafe_embeddings refuses all of them here too -- confirmed
// directly against the real generated output: RPG2k::Window does not
// appear in bc2cpp's own "classes needing MRB_SET_INSTANCE_TT(...,
// MRB_TT_DATA)" diagnostic, and no DATA_PTR(self) access appears anywhere
// in its own compiled methods below.
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

  // Game::Actor (docs/adr/0139's own GETIDX/SETIDX/GETGV follow-up) -- 76
  // real methods (up from 75 -- see #set_exp's own entry below, added by
  // this file's Game::Party round's own full-sweep re-check), in
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
  mrb_define_method(M, actor, "knock_out!", Game__Actor_knock_out_,
                    MRB_ARGS_NONE());
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
  mrb_define_method(M, actor, "restore_class", Game__Actor_restore_class,
                    MRB_ARGS_REQ(1));
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
}

extern "C" void mrb_mruby_rpg2k_compiled_gem_final(mrb_state*) {}
