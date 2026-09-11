// Swaps AOT-compiled C++ bodies in for all 17 of RGSS::Sprite's own real
// bytecode-defined methods (docs/adr/0139) -- every plain Ruby reader
// mruby-rgss/mrblib/lib.rb reopens the native Sprite class with, made
// possible by this same follow-up's own JMPNIL/LOADL opcode additions
// (opacity/zoom_x/zoom_y's own `@ivar.nil? ? default : @ivar` shape) and
// GETCONST owner-scope-first fix (tone/color/src_rect's own
// `Tone.new(...)`/`Color.new(...)`/`Rect.new(...)` -- each of those three
// classes is defined on the *enclosing* RGSS module, not on Sprite itself
// nor Object, a real bug the original single-scope-from-Object GETCONST
// codegen would have hit for exactly these three methods). mruby-rgss
// (this gem's own add_dependency) has already run its full gem init -- C
// hook *and* mrblib -- by the time this gem's own init runs, so Sprite is
// guaranteed to already exist below, already a native MRB_TT_DATA class.
//
// No ivar embedding here: all 17 compiled methods are pure readers (the
// real writers -- `x=`/`y=`/`opacity=`/... -- are native, defined in
// mruby-rgss/src/lib.cxx, invisible to bc2cpp the same way every other
// native method there is), so bc2cpp's own drop_unsafe_embeddings guard
// never even considers RGSS::Sprite (no compiled #initialize to allocate
// a struct in) -- every GETIV/SETIV below stays on the ordinary dynamic
// iv_tbl, exactly matching the interpreter's own behavior and coexisting
// fine with Sprite's native RData payload (mruby/data.h: an RData carries
// both a `data` pointer and a normal `iv` table).
//
// RGSS::Plane (docs/adr/0139's own follow-up, this gem's second owner)
// gets the same treatment for its own 6 real bytecode-defined methods
// (opacity/zoom_x/zoom_y/blend_type/tone/color) -- plain Ruby readers
// answering RGSS defaults for ivars only Plane's native #initialize
// (mruby-rgss/src/lib.cxx) ever sets, the exact same shape as Sprite's
// own identically-named methods above, reusing the same JMPNIL/ternary,
// `||`, and owner-scope-first GETCONST codegen with zero new bc2cpp.rb
// work. `attr_reader :bitmap, :ox, :oy, :z, :viewport` stays native/
// uncompiled, as always. Plane has no #initialize of its own at all (the
// native one is invisible to bc2cpp, same as every other native method),
// so bc2cpp's own drop_unsafe_embeddings guard never even considers
// RGSS::Plane either -- confirmed directly against the real diagnostic:
// it never appears in bc2cpp's own "classes needing
// MRB_SET_INSTANCE_TT" listing. Every GETIV/SETIV below stays on the
// ordinary dynamic iv_tbl, same as Sprite.
//
// RGSS::Tilemap (this gem's third owner) gets the same treatment for its
// one real bytecode-defined method, #autotiles (`@autotiles ||=
// Array.new(7)`, RGSS's own fixed 7-slot autotile table) -- reusing the
// same GETIV/JMPIF-guarded-GETCONST+SEND+SETIV `||=` lowering as
// Sprite's/Plane's own `@tone ||=`/`@color ||=`, just resolving a bare
// core class (`Array`) instead of an RGSS-namespaced one: the
// owner-scope-first chain still finds it, only by falling all the way
// through to its final unprotected Object-level `mrb_const_get` rather
// than matching at the RGSS scope the way Tone/Color did (see
// compiled_gems.rb's own comment for the real regenerated-body
// confirmation). `attr_reader :tileset, :map_data, :ox, :oy, :viewport,
// :priorities, :flags` and `attr_accessor :flash_data` stay
// native/uncompiled, as always. Tilemap has no #initialize of its own
// either, so it hits the same drop_unsafe_embeddings class-level
// exclusion as Plane -- confirmed directly: it never appears in bc2cpp's
// own "classes needing MRB_SET_INSTANCE_TT" listing. Its one GETIV/SETIV
// stays on the ordinary dynamic iv_tbl, same as Sprite and Plane.
//
// RGSS::Window (docs/adr/0139's own follow-up, this gem's third owner)
// gets 12 of its own real bytecode-defined methods compiled: opacity/
// back_opacity/active/pause/stretch/openness (the same `@ivar.nil? ?
// default : @ivar` / `@ivar || false` reader shape as Sprite/Plane
// above), cursor_rect (a `@cursor_rect ||= Rect.new(0, 0, 0, 0)`
// memoizing reader, the exact `||=` + owner-scope-first-GETCONST shape
// Sprite's own `@tone ||=`/`@color ||=` already established), padding/
// arrows_visible (the same nil-guarded-default reader shape again), and
// open?/close?/padding_bottom -- each a same-class, same-owner
// self-implicit call to another already-compiled RGSS::Window reader
// (`openness`/`openness`/`padding`, respectively), MONO-devirtualized
// by compile_send into a direct C++ call to that other method's own
// _impl, never an mrb_funcall, the identical mechanism already proven
// for every other same-owner self-call in this whole program. `x`/`y`/
// `width`/`height`/`ox`/`oy`/`z`/`viewport`/`windowskin`/`contents`/
// `contents_opacity` (`attr_reader`) stay native/uncompiled, as always.
//
// RGSS::Bitmap (this gem's fifth owner, mruby-rgss/mrblib/lib.rb) gets 2 of
// its own real bytecode-defined methods compiled: `#font`
// (`@font ||= Font.new`, the same `||=` + owner-scope-first-GETCONST
// memoizing-reader shape Sprite's own `@tone ||=`/`@color ||=` and
// Window's own `@cursor_rect ||=` already established -- `Font` resolves
// at the `RGSS` scope, same as `Tone`/`Color`/`Rect`) and `#font=`
// (`@font = f`, a plain one-argument SETIV setter). Everything else on
// this class stays uncompiled:
//
// `#initialize(f, s = nil)` has one real optional argument, hitting the
// same `pure_mandatory_arity?` gate as `RGSS::Window#initialize` below
// (`#error RGSS::Bitmap#initialize has non-mandatory arguments
// (optional/rest/keyword/block) -- not in this prototype's supported
// subset`), confirmed directly against the real generated output before
// `SKIP_UNSUPPORTED=1` drops it.
//
// The private `#init_from_archive(f, s)` has pure mandatory arity (2
// args) but its own real body hits three distinct unsupported opcodes in
// sequence, confirmed directly rather than assumed identical to some
// other class's own rescue-clause gap: `Bitmap.extensions.each do |ext|
// ... end` (a real block argument) emits `#error unhandled opcode BLOCK`
// immediately followed by `#error unhandled opcode SENDB` -- both fire
// *before* codegen ever reaches the method's own trailing `rescue
// StandardError => e ... end`, which separately emits `#error unhandled
// opcode EXCEPT` then `#error unhandled opcode RESCUE`. The `.each` block
// is the first real gap this method hits, not the rescue clause alone.
//
// The nested `RGSS::Bitmap::LoadError#initialize(path, reason)` has pure
// mandatory arity (2 args) and its own `#{path}`/`#{reason}` string
// interpolation compiles clean (STRING/STRCAT), but its trailing
// `super("Failed to init bitmap: #{path} (#{reason})")` call hits
// `#error unhandled opcode SUPER` -- the same, already-documented SUPER
// gap every other `#initialize`-calling-`super` in this codebase hits,
// confirmed here via this method's own real marker rather than assumed
// identical merely because the shape (a nested exception class calling
// `super` with a formatted message) looks familiar. `RGSS::Bitmap::
// LoadError` is not itself a member of this gem's `owners:` list -- its
// own owner string is the distinct `RGSS::Bitmap::LoadError`, not
// `RGSS::Bitmap` -- so with only `RGSS::Bitmap` in `ONLY_OWNERS` this
// method is never even emitted; confirmed separately by adding
// `RGSS::Bitmap::LoadError` to `ONLY_OWNERS` in an isolated diagnostic
// run and reading the real `#error unhandled opcode SUPER` marker it
// then produces.
//
// `class << self; attr_writer :extensions; def extensions; @extensions
// || EXTENSIONS; end; end` and `def self.failure_reason(f)` both live
// under the distinct pseudo-owner `RGSS::Bitmap.singleton` (SCLASS/SDEF,
// this ADR's own established fix), never under `RGSS::Bitmap` itself --
// neither is reachable with only `RGSS::Bitmap` in `ONLY_OWNERS`, and
// neither is added here: no `owners:` list in this project has ever
// named a `.singleton` pseudo-owner (every prior follow-up's own
// full-sweep verification confirms "no pseudo-owner symbol ever linked
// anywhere"), so this stays consistent with that precedent. Checked
// anyway, since verifying `self.failure_reason` against the real
// diagnostic (rather than assuming the established SDEF registry fix
// makes it compilable) was explicitly part of this round's own task: it
// does not compile, for a deeper reason than its own body's opcodes
// (`if`/early `return`/array `<<`/`.join`/string interpolation are all
// otherwise-supported shapes) -- `def self.x` outside any `class << self`
// block always compiles to a single fused `SDEF` instruction (confirmed
// directly via `mrbc -v` disassembly: `SDEF R1 :failure_reason I[3]`),
// and bc2cpp.rb's own SDEF case registers that as a synthetic `MethodDef`
// with `irep: nil` unconditionally, by design ("there is no separate
// body to recurse into", bc2cpp.rb's own comment) -- so `compile_all`'s
// `@owner_of` never gains a real entry for it at all. It is therefore not
// merely left uncompiled the way an arity/opcode gap leaves a method
// uncompiled (those still leave a `#error`-marked stub, which survives
// into the "skipped (unsupported)" summary) -- `self.failure_reason` is
// invisible to `compile_all`'s own leaf worklist from the start: it
// appears in neither the "skipped" list nor the generated file at all
// (confirmed: zero matches for `failure_reason` anywhere in the real
// generated `rgss_compiled_gen.cpp`, with or without
// `SKIP_UNSUPPORTED`), and would stay that way regardless of what its own
// body did. `self.extensions` (defined inside the real `class << self
// ... end` block, an `SCLASS`-opened body that *does* recurse -- this
// ADR's own established fix for exactly that) is by contrast a real,
// individually compilable leaf with its own irep (confirmed: it appears
// in the real generated output, `RGSS__Bitmap_singleton_extensions_impl`,
// once `RGSS::Bitmap.singleton` is added to `ONLY_OWNERS` in an isolated
// check), but is left out of this round's `owners:` for the same
// never-a-`.singleton`-owner precedent `self.failure_reason` is.
// `attr_writer :extensions`'s own `extensions=` is `Module#attr_writer`'s
// native/C-installed setter (no bytecode DEF at all, the same as every
// other `attr_writer`/`attr_accessor`-defined method elsewhere in this
// codebase), invisible to bc2cpp regardless of owner scoping.
//
// Embedding: none, confirmed directly against the real diagnostic --
// RGSS::Bitmap never appears in bc2cpp's own "classes needing
// MRB_SET_INSTANCE_TT" listing. drop_unsafe_embeddings's own class-level
// gate requires a *compiling* #initialize with pure mandatory arity
// before embedding anything on a class at all; RGSS::Bitmap#initialize
// doesn't compile (non-mandatory arity, the same gate RGSS::Window's own
// #initialize hits below), so nothing on this class is ever even
// proposed as an embedding candidate. @font is a Font object reference
// (never Fixnum/Symbol) and would not be a FixnumEmbed/SymbolEmbed
// candidate regardless of that gate either way.
//
// RGSS::Window#initialize -- the one method on this class this gem does
// NOT compile -- has 4 real optional arguments (`x = nil, y = nil,
// width = nil, height = nil`), hitting bc2cpp's own pure_mandatory_arity?
// gate (`#error RGSS::Window#initialize has non-mandatory arguments
// (optional/rest/keyword/block) -- not in this prototype's supported
// subset`), confirmed directly against the real generated output before
// SKIP_UNSUPPORTED=1 drops it. This class's own real source also calls
// `alias_method :_rgss1_initialize, :initialize` right before
// redefining #initialize, to keep the RGSS1 (XP) native initializer
// reachable from the RGSS2/3 (VX/VX Ace) Ruby-level override below it --
// a genuinely new shape for this ADR: `alias_method` is a plain
// self-implicit `SSEND :alias_method` call, not the dedicated `alias`
// keyword's own `OP_ALIAS` bytecode instruction, so it creates no TDEF/
// DEF pair for `_rgss1_initialize` at all. bc2cpp's build_registry walks
// only TDEF/DEF pairs to populate its name registry, so `_rgss1_initialize`
// never enters it under any name -- confirmed directly: grepping both the
// full registry dump and the generated output for `_rgss1_initialize`/
// `rgss1` finds zero matches anywhere, and a standalone disassembly of an
// `alias_method`-using class (`mrbc -v -S`) shows the two real `def
// initialize`s each get their own `TDEF ... :initialize`, while
// `alias_method` itself lowers to an ordinary `SSEND R1 :alias_method
// n=2` with no opcode of its own. This makes an alias_method-created name
// invisible to the registry the same *way* a native or `class << self`-
// reopened method already is (both are also invisible to a plain TDEF/DEF
// walk), but through a third, structurally distinct cause neither of
// those two already-documented gaps shares: a native method is scraped
// back in from NATIVE_SRCS by a separate regex pass, and a singleton
// method gets its own real DEF under a synthesized `.singleton` pseudo-
// owner -- `alias_method` has no equivalent backfill of any kind, so the
// alias name is not merely mis-attributed, it is entirely absent from the
// registry. Harmless here specifically because the only real call site
// for `_rgss1_initialize` (RGSS::Window#initialize's own body) never
// itself compiles -- the non-mandatory-arity #error fires before that
// body's own SEND instructions are ever inspected, so this gap is never
// actually exercised by any real, currently-shipped call site in this
// closed world. Since #initialize doesn't compile, this class also gets
// no ivar embedding at all (drop_unsafe_embeddings's own class-level gate
// requires a *compiling* #initialize with pure mandatory arity before
// embedding anything on a class), confirmed directly against the real
// diagnostic: RGSS::Window never appears in bc2cpp's own "classes needing
// MRB_SET_INSTANCE_TT" listing. Every GETIV/SETIV below stays on the
// ordinary dynamic iv_tbl, same as Sprite/Plane.
#include <mruby.h>
#include <mruby/class.h>

// Generated at build time by tools/bc2cpp/bc2cpp.rb from mruby-rgss's own
// real mrblib/lib.rb (mrbgem.rake's own `file` rule runs it before this
// translation unit is compiled).
#include "rgss_compiled_gen.cpp"

extern "C" void mrb_mruby_rgss_compiled_gem_init(mrb_state* M) {
  RClass* rgss = mrb_module_get(M, "RGSS");
  RClass* sprite = mrb_class_get_under(M, rgss, "Sprite");

  mrb_define_method(M, sprite, "opacity", RGSS__Sprite_opacity,
                    MRB_ARGS_NONE());
  mrb_define_method(M, sprite, "zoom_x", RGSS__Sprite_zoom_x, MRB_ARGS_NONE());
  mrb_define_method(M, sprite, "zoom_y", RGSS__Sprite_zoom_y, MRB_ARGS_NONE());
  mrb_define_method(M, sprite, "blend_type", RGSS__Sprite_blend_type,
                    MRB_ARGS_NONE());
  mrb_define_method(M, sprite, "tone", RGSS__Sprite_tone, MRB_ARGS_NONE());
  mrb_define_method(M, sprite, "color", RGSS__Sprite_color, MRB_ARGS_NONE());
  mrb_define_method(M, sprite, "width", RGSS__Sprite_width, MRB_ARGS_NONE());
  mrb_define_method(M, sprite, "height", RGSS__Sprite_height, MRB_ARGS_NONE());
  mrb_define_method(M, sprite, "x", RGSS__Sprite_x, MRB_ARGS_NONE());
  mrb_define_method(M, sprite, "y", RGSS__Sprite_y, MRB_ARGS_NONE());
  mrb_define_method(M, sprite, "z", RGSS__Sprite_z, MRB_ARGS_NONE());
  mrb_define_method(M, sprite, "ox", RGSS__Sprite_ox, MRB_ARGS_NONE());
  mrb_define_method(M, sprite, "oy", RGSS__Sprite_oy, MRB_ARGS_NONE());
  mrb_define_method(M, sprite, "angle", RGSS__Sprite_angle, MRB_ARGS_NONE());
  mrb_define_method(M, sprite, "mirror", RGSS__Sprite_mirror, MRB_ARGS_NONE());
  mrb_define_method(M, sprite, "bush_depth", RGSS__Sprite_bush_depth,
                    MRB_ARGS_NONE());
  mrb_define_method(M, sprite, "src_rect", RGSS__Sprite_src_rect,
                    MRB_ARGS_NONE());

  RClass* plane = mrb_class_get_under(M, rgss, "Plane");

  mrb_define_method(M, plane, "opacity", RGSS__Plane_opacity, MRB_ARGS_NONE());
  mrb_define_method(M, plane, "zoom_x", RGSS__Plane_zoom_x, MRB_ARGS_NONE());
  mrb_define_method(M, plane, "zoom_y", RGSS__Plane_zoom_y, MRB_ARGS_NONE());
  mrb_define_method(M, plane, "blend_type", RGSS__Plane_blend_type,
                    MRB_ARGS_NONE());
  mrb_define_method(M, plane, "tone", RGSS__Plane_tone, MRB_ARGS_NONE());
  mrb_define_method(M, plane, "color", RGSS__Plane_color, MRB_ARGS_NONE());

  RClass* tilemap = mrb_class_get_under(M, rgss, "Tilemap");

  mrb_define_method(M, tilemap, "autotiles", RGSS__Tilemap_autotiles,
                    MRB_ARGS_NONE());

  RClass* window = mrb_class_get_under(M, rgss, "Window");

  mrb_define_method(M, window, "opacity", RGSS__Window_opacity,
                    MRB_ARGS_NONE());
  mrb_define_method(M, window, "back_opacity", RGSS__Window_back_opacity,
                    MRB_ARGS_NONE());
  mrb_define_method(M, window, "cursor_rect", RGSS__Window_cursor_rect,
                    MRB_ARGS_NONE());
  mrb_define_method(M, window, "active", RGSS__Window_active, MRB_ARGS_NONE());
  mrb_define_method(M, window, "pause", RGSS__Window_pause, MRB_ARGS_NONE());
  mrb_define_method(M, window, "stretch", RGSS__Window_stretch,
                    MRB_ARGS_NONE());
  mrb_define_method(M, window, "openness", RGSS__Window_openness,
                    MRB_ARGS_NONE());
  mrb_define_method(M, window, "open?", RGSS__Window_open_, MRB_ARGS_NONE());
  mrb_define_method(M, window, "close?", RGSS__Window_close_, MRB_ARGS_NONE());
  mrb_define_method(M, window, "padding", RGSS__Window_padding,
                    MRB_ARGS_NONE());
  mrb_define_method(M, window, "padding_bottom", RGSS__Window_padding_bottom,
                    MRB_ARGS_NONE());
  mrb_define_method(M, window, "arrows_visible", RGSS__Window_arrows_visible,
                    MRB_ARGS_NONE());

  RClass* bitmap = mrb_class_get_under(M, rgss, "Bitmap");

  mrb_define_method(M, bitmap, "font", RGSS__Bitmap_font, MRB_ARGS_NONE());
  mrb_define_method(M, bitmap, "font=", RGSS__Bitmap_font_, MRB_ARGS_REQ(1));
}

extern "C" void mrb_mruby_rgss_compiled_gem_final(mrb_state*) {}
