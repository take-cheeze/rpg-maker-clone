// Swaps AOT-compiled C++ bodies in for 25 of Game::Picture's own 26 real
// methods (docs/adr/0139's own follow-up) -- everything but #initialize,
// which takes optional arguments bc2cpp's calling convention doesn't
// model, so it keeps running mruby-rpg2k's own interpreted mrblib body
// unchanged -- plus, as of docs/adr/0139 (the JMPNIL/LOADL opcode work),
// all 6 of Game::EnemyAction's own real bytecode-defined methods (its
// `attr_reader`-generated accessors are native, invisible to bc2cpp the
// same way every other attr_reader/attr_writer in this codebase is) --
// plus, as of docs/adr/0139's own array-literal-opcode follow-up (two
// classes compiled in the same round), 39 of Game::Screen's own 43 real
// bytecode-defined methods, INCLUDING #initialize itself this time (see
// that class's own registration block below for why it's different from
// the other three), and 32 of RPG2k::Window's own 35 real methods
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
// two classes together rather than in isolation.
// mruby-rpg2k (this gem's own add_dependency) has already run its full gem
// init -- C hook *and* mrblib -- by the time this gem's own init runs
// (mrbgems.rake sequences gem_funcs[] in dependency order, each entry
// running its complete init before the next gem's own init starts), so
// all four classes are guaranteed to already exist below.
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
  // 4 real methods stay interpreted: #load_h destructures a Hash literal
  // into locals (`h[:pan_x]`) via GETIDX, an opcode outside this
  // prototype's modeled subset; #erase/#show both take an optional
  // `frames = nil` argument (the same non-mandatory-arity gap that already
  // keeps Game::Picture#initialize/RPG2k::Window#initialize interpreted);
  // #pan uses GETIDX too (`PAN_DELTA[direction]`, a real Hash#[] lookup,
  // distinct from AREF's own destructuring-assignment-only real VM
  // semantics -- see AREF's own compile_insn comment).
  RClass* screen = mrb_class_get_under(M, game, "Screen");
  MRB_SET_INSTANCE_TT(screen, MRB_TT_DATA);

  // #initialize is always private (the same real interpreter special case
  // as Game::EnemyAction#initialize above -- mruby's own src/class.c forces
  // it regardless of source, not a bare `private` call here).
  mrb_define_private_method(M, screen, "initialize", Game__Screen_initialize,
                            MRB_ARGS_NONE());
  mrb_define_method(M, screen, "to_h", Game__Screen_to_h, MRB_ARGS_NONE());
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
}

extern "C" void mrb_mruby_rpg2k_compiled_gem_final(mrb_state*) {}
