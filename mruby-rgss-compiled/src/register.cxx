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
// this ADR's own established fix), never under `RGSS::Bitmap` itself.
//
// Follow-up (docs/adr/0139: ".singleton owner support"): both are now
// real, compiled entry points -- `RGSS::Bitmap.singleton` was added to
// this gem's own `owners:` (tools/bc2cpp/compiled_gems.rb), the first
// `.singleton`-suffixed `owners:` entry anywhere in this project, made
// possible by that same follow-up's own fix to bc2cpp.rb's SDEF case
// (previously registered a `def self.x` method's own MethodDef with
// `irep: nil` unconditionally, discarding a real, compilable child irep
// mrbc's own SDEF opcode already carries -- see build_registry's own
// SDEF case for the real bug this closed, confirmed live on exactly this
// class's own `self.failure_reason`). `self.extensions` (an SCLASS-opened
// body, already individually compilable via this ADR's own earlier SCLASS
// fix) compiles to the same `||`-default-array reader shape
// `RGSS::Window#blend_type`/`#stretch` already ship
// (`RGSS__Bitmap_singleton_extensions_impl`). `self.failure_reason(f)`
// -- previously assumed structurally incapable of ever compiling, for a
// reason independent of its own body -- turned out to compile clean too
// once given a real irep: its `if`/early `return`/array `<<`/`.join`/
// string interpolation are all otherwise-supported shapes, and its one
// call into `extensions` (bare, self-implicit) correctly MONO-
// devirtualizes into `RGSS__Bitmap_singleton_extensions_impl` directly (no
// `mrb_funcall`) -- confirmed directly in the real generated output, both
// methods now living under this same class's own owner in this file.
// Both are registered below via `mrb_define_class_method`, not
// `mrb_define_method`: `self` in either compiled body is the `Bitmap`
// class object itself, never an instance. `attr_writer :extensions`'s
// own `extensions=` is `Module#attr_writer`'s native/C-installed setter
// (no bytecode DEF at all, the same as every other
// `attr_writer`/`attr_accessor`-defined method elsewhere in this
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

  // RGSS::Bitmap.singleton (docs/adr/0139: ".singleton owner support") --
  // this project's first `.singleton`-owned bc2cpp entries. Both are real
  // `class << self`/`def self.x` singleton methods (see
  // mruby-rgss/mrblib/lib.rb), installed onto `bitmap`'s own singleton
  // class via mrb_define_class_method, not mrb_define_method: `self`
  // inside either compiled body is the Bitmap class object itself, not an
  // instance, and mrb_define_method would instead (wrongly) install onto
  // Bitmap's own *instance* method table, reachable only via
  // `some_bitmap.extensions`/`some_bitmap.failure_reason(f)`, never the
  // real `Bitmap.extensions`/`Bitmap.failure_reason(f)` call sites this
  // class's own #initialize actually uses. Reuses the exact same `bitmap`
  // RClass* declared just above for the instance-level registrations --
  // mrb_define_class_method resolves the receiver's own singleton class
  // internally, so no separate RClass* is needed even though this is a
  // structurally different method table from font/font='s own.
  mrb_define_class_method(M, bitmap, "extensions",
                          RGSS__Bitmap_singleton_extensions, MRB_ARGS_NONE());
  mrb_define_class_method(M, bitmap, "failure_reason",
                          RGSS__Bitmap_singleton_failure_reason,
                          MRB_ARGS_REQ(1));
}

extern "C" void mrb_mruby_rgss_compiled_gem_final(mrb_state*) {}
