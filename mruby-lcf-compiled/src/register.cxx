// Swaps AOT-compiled C++ bodies in for a hand-picked, provably-safe subset
// of LCF::File/Database/MapTree/MapUnit/SaveData's own bytecode methods
// (docs/adr/0139), plus LCF::File#[]/#[]= (a later follow-up's own fix --
// see this class's own registration block below for why these two were a
// real, previously-missed coverage gap, not the pre-existing interpreted
// fallback the rest of this paragraph describes), LCF::MoveCommand#initialize,
// LCF::EventCommand#initialize/#param, LCF::Tree#initialize,
// LCF::Sections's own 4 methods, LCF::Array1D's own 5 methods, and
// LCF::Array2D's own 2 methods
// (docs/adr/0139's own follow-ups, mruby-lcf/mrblib/lcf.rb). mruby-lcf
// (this gem's own add_dependency) has already run its full gem init --
// C hook *and* mrblib -- by the time this gem's own init runs
// (mrbgems.rake sequences gem_funcs[] in dependency order, each entry
// running its complete init before the next gem's own init starts), so
// every class fetched below is guaranteed to already exist.
//
// Every method NOT registered here (LCF::File#initialize,
// #method_missing, #respond_to_missing?, #save_to, ...) is untouched:
// mruby-lcf's own mrblib already defined it moments ago, and it keeps
// running on the ordinary interpreted bytecode path -- the documented
// fallback for anything bc2cpp couldn't safely compile.
//
// LCF::Tree (mruby-lcf/mrblib/lcf.rb, right above LCF::EventCommand) -- one
// decoded map-tree section (the currently-selected map id plus the flat
// list of every map id in tree order; LCF::MapTree's own `:tree` section).
// #initialize is the ONLY real bytecode-defined method on this class
// (`attr_reader :selected_id, :maps` stays native, uncompiled, as always)
// and it compiles clean: 2 purely mandatory arguments, no super, no block.
// Registered below. Unlike LCF::EventCommand above, this class carries no
// `# bc2cpp:` type annotation, and neither @selected_id nor @maps traces to
// a literal or an annotated argument, so neither is even proposed for
// embedding by the real diagnostic today (both show up only in its
// `report_annotation_candidates` list, never an EMBED proposal) --
// confirmed this class does not appear in bc2cpp's own "classes needing
// MRB_SET_INSTANCE_TT" diagnostic, so no MRB_SET_INSTANCE_TT call belongs
// in its own registration block below. Checked one step further anyway,
// per this project's own established discipline: temporarily annotating
// #initialize `# bc2cpp: (fixnum, )` (matching @selected_id's real
// construction sites, both always a `read_ber` result) and re-running the
// real diagnostic confirms this class STILL does not appear in that list
// and the regenerated #initialize body still writes @selected_id via plain
// `mrb_iv_set`, never `mrb_data_init` -- i.e. its own `attr_reader
// :selected_id` would have collided with an embedded @selected_id exactly
// the same way LCF::EventCommand's `attr_reader :code, :indent` did above,
// and `natively_exposed?` correctly suppresses it too. That experimental
// annotation was reverted before this commit -- the real, shipped source
// carries none, so the point is moot today for a second, independent
// reason (no type information reaches the embedding pass at all without
// it), but confirmed live rather than assumed. @maps (an Array) was never
// a Fixnum/Symbol candidate either way.
//
// LCF::Sections (mruby-lcf/mrblib/lcf.rb, docs/adr/0139's own follow-up)
// -- holds the sequential sections of a multi-section file (currently
// only LCF::MapTree's own Array-shaped schema), built once by
// LCF::File#initialize whenever its own `schema` is an Array. All 4 of
// its own real bytecode-defined methods compile clean and are registered
// below: #initialize (2 plain Hash/Array literal SETIVs, no arguments at
// all -- always private, same as every other compiled #initialize in
// this project), #add, #key?, and #[] (its own `idx.is_a? Symbol` guard
// is an ordinary POLY send into the native `is_a?`, needing no new
// bc2cpp.rb opcode work). #method_missing/#respond_to_missing? stay
// interpreted, same as every other method_missing-using class here.
// @by_name/@list are a Hash and an Array (never Fixnum/Symbol), so
// nothing on this class is embeddable -- confirmed directly: it never
// appears in bc2cpp's own "classes needing MRB_SET_INSTANCE_TT"
// diagnostic, so no MRB_SET_INSTANCE_TT call belongs in this class's own
// registration block below.
//
// LCF::Array1D (mruby-lcf/mrblib/lcf.rb, right above LCF::Array2D) -- the
// sequential chunk-id -> raw-bytes record every LCF::File-family object
// actually decodes through. A more complex class than LCF::Tree/
// LCF::Sections above (11 real bytecode-defined methods, not 1-4), so only
// 5 of them compile clean and are registered below: #[], #key?,
// #int16_values, #delete, #[]= -- all public, pure mandatory arity, no
// super, no block. See tools/bc2cpp/compiled_gems.rb's own LCF::Array1D
// comment for the full per-method writeup, including exactly why each of
// the other 6 real methods (#initialize, #to_lcf, #method_missing,
// #respond_to_missing?, #sym2idx, plus the native `attr_reader :schema`)
// stays interpreted: #initialize's own `loop do ... end` and #sym2idx's
// own `LCF.elements_of(@schema).each { |k, e| ... }` are both real
// BLOCK/S(S)ENDB blocks (loop is an ordinary Kernel#loop method call
// taking a block, not the already-supported JMP/JMPNOT back-edge shape a
// plain `while`/`until` keyword loop compiles to -- confirmed directly
// against the real generated body, not assumed from the source shape);
// #to_lcf/#respond_to_missing? each have one optional argument; #method_
// missing has a rest argument. No MRB_SET_INSTANCE_TT call belongs in this
// class's own registration block below: @data (Array of Strings) and
// @schema (a Hash, per its own `# bc2cpp: (, Hash)` annotation) are never
// Fixnum/Symbol, so this class never appears in bc2cpp's own "classes
// needing MRB_SET_INSTANCE_TT" diagnostic -- confirmed directly, not
// assumed from the ivar types alone.
//
// LCF::Array2D (mruby-lcf/mrblib/lcf.rb, right below LCF::Array1D) -- the
// id-keyed table of rows an LCF::File-family object's project-map tree /
// database item/actor/skill/... list decodes through; each row is itself
// an Array1D chunk stream, decoded lazily. A different method shape from
// Array1D above it, not its structural twin (confirmed by reading the
// real source, not assumed): 6 real bytecode-defined methods, not 11, and
// no #method_missing/#respond_to_missing? at all (rows are indexed purely
// by integer id, with no symbolic per-field accessor to dispatch
// through). Only 2 of them compile clean and are registered below: #[]
// (lazily decodes and in-place caches a row's raw byte span into a real
// `Array1D.new(entry, @schema)` on first access) and #[]= (a bare
// `@data[idx] = entry` SETIDX, simpler than Array1D's own #[]=). Both
// public, pure mandatory arity, no super, no block. See tools/bc2cpp/
// compiled_gems.rb's own LCF::Array2D comment for the full per-method
// writeup, including exactly why the other 4 real methods (#initialize,
// #each, #to_lcf, #read_row_bytes) stay interpreted: #initialize's own
// `(0...LCF.read_ber(s)).each do ... end` (a Range#each method call
// taking a block -- NOT the same on-disk shape as Array1D#initialize's
// own id/len/bytes `loop`, confirmed directly by reading the source),
// #each's own `@data.size.times do |i| ... end`, and the private
// #read_row_bytes's own `loop do ... end` are all real BLOCK/S(S)ENDB
// blocks, the same established gap as every other genuine-Ruby-block
// method in this codebase; #to_lcf has no arguments at all but hits the
// same BLOCK/SENDB pair twice independently (`@data.each_with_index`
// then `ids.each`). No MRB_SET_INSTANCE_TT call belongs in this class's
// own registration block below: @data (an Array, holding raw byte-span
// Strings until lazily replaced by decoded Array1D instances) and
// @schema (a Hash) are never Fixnum/Symbol, so this class never appears
// in bc2cpp's own "classes needing MRB_SET_INSTANCE_TT" diagnostic --
// confirmed directly. This class carries no attr_reader/attr_writer/
// attr_accessor at all, so there is no native-accessor/embedded-ivar
// collision surface here either.
//
// LCF::EventCommand (mruby-lcf/mrblib/lcf.rb) -- one decoded RPG2000
// event-page/common-event/move-route command (code, indent, an optional
// string argument, and an integer parameter list). #initialize already
// carried a real `# bc2cpp: (fixnum, fixnum, , )` annotation from an
// earlier round's dynamic profiling pass, but was never actually added
// as a compiled owner until now. Both of its own real bytecode-defined
// methods compile clean and are registered below: #initialize (4 purely
// mandatory arguments, no super, no block -- plain SETIVs) and #param
// (`@parameters[i] || 0`, a Hash/Array GETIDX plus a `||` default).
// `attr_reader :code, :indent, :string, :parameters` stays native,
// uncompiled, same as every other attr_reader in this codebase.
//
// Checked directly against the real generated output rather than
// trusted from the annotation alone (per this project's own established
// discipline): despite @code/@indent both being provably Fixnum, this
// class does NOT get any real RData embedding. Its own `attr_reader
// :code, :indent, ...` covers those same two names, and a plain
// attr_reader's native `mrb_iv_get` implementation (3rd/mruby/src/
// class.c) has no way to see a value this class's own SETIV codegen
// would otherwise write into an embedded struct field instead -- a real,
// live bug this round's own dedicated bug-hunt found and fixed at the
// root (bc2cpp.rb's drop_unsafe_embeddings), see
// mruby-rpg2k-compiled/src/register.cxx's own top comment for the full
// writeup and the four already-shipped classes (Game::State/Map/
// ChipSet/Switches) it was already live in. Confirmed directly: this
// class does not appear in bc2cpp's own "classes needing
// MRB_SET_INSTANCE_TT" diagnostic, no `LCF__EventCommand_ivars` struct
// is generated, and #initialize's own compiled body writes @code/
// @indent/@string/@parameters via plain `mrb_iv_set`, exactly like every
// other (non-embedding) compiled #initialize in this gem -- so no
// MRB_SET_INSTANCE_TT call belongs in this class's own registration
// block below.
#include <mruby.h>
#include <mruby/class.h>

// Generated at build time by tools/bc2cpp/bc2cpp.rb from mruby-lcf's own
// real mrblib/lcf_file.rb (mrbgem.rake's own `file` rule runs it before
// this translation unit is compiled). Defines LCF__File_header,
// LCF__Database_schema, ... (both the `_impl(mrb_state*, mrb_value, ...)`
// direct-call form and the plain `mrb_func_t`-shaped entry point every
// mrb_define_method call below actually registers) as ordinary `static`
// functions in this same translation unit.
#include "lcf_compiled_gen.cpp"

extern "C" void mrb_mruby_lcf_compiled_gem_init(mrb_state* M) {
  RClass* lcf = mrb_module_get(M, "LCF");
  RClass* file = mrb_class_get_under(M, lcf, "File");
  RClass* database = mrb_class_get_under(M, lcf, "Database");
  RClass* map_tree = mrb_class_get_under(M, lcf, "MapTree");
  RClass* map_unit = mrb_class_get_under(M, lcf, "MapUnit");
  RClass* save_data = mrb_class_get_under(M, lcf, "SaveData");
  RClass* tree = mrb_class_get_under(M, lcf, "Tree");

  // LCF::Tree (docs/adr/0139's own follow-up): one decoded map-tree section
  // (the currently-selected map id plus the flat list of every map id in
  // tree order). #initialize is the ONLY real bytecode-defined method on
  // this class (`attr_reader :selected_id, :maps` stays native, uncompiled,
  // as always), and it compiles clean: 2 purely mandatory arguments, no
  // super, no block -- confirmed directly against the real diagnostic's own
  // `== compiled entry points ==` listing, which flags it private (mruby's
  // own always-private #initialize special case, not a source-level
  // `private` call). See this file's own top comment for why no
  // MRB_SET_INSTANCE_TT call belongs here -- neither @selected_id nor @maps
  // is embedded, confirmed directly against the real generated output, not
  // just this class's own attr_reader shape by analogy.
  mrb_define_private_method(M, tree, "initialize", LCF__Tree_initialize,
                            MRB_ARGS_REQ(2));

  RClass* sections = mrb_class_get_under(M, lcf, "Sections");

  // #initialize is always private (mruby's own src/class.c forces this
  // regardless of source), so this uses mrb_define_private_method, not
  // mrb_define_method -- confirmed directly against the real
  // diagnostic's own `== compiled entry points ==` listing, which flags
  // it accordingly. #add/#key?/#[] are public; no bare
  // `private`/`protected`/`public` anywhere in this class's own real
  // source. See this file's own top comment for why no
  // MRB_SET_INSTANCE_TT call belongs here.
  mrb_define_private_method(M, sections, "initialize", LCF__Sections_initialize,
                            MRB_ARGS_NONE());
  mrb_define_method(M, sections, "add", LCF__Sections_add, MRB_ARGS_REQ(2));
  mrb_define_method(M, sections, "key?", LCF__Sections_key_, MRB_ARGS_REQ(1));
  mrb_define_method(M, sections, "[]", LCF__Sections___, MRB_ARGS_REQ(1));

  RClass* event_command = mrb_class_get_under(M, lcf, "EventCommand");

  // #initialize is always private (mruby's own src/class.c forces this
  // regardless of source, not a bare `private` call in the real
  // interpreted source -- the same always-private special case every
  // other compiled #initialize in this project already documents).
  // #param is public; no bare `private`/`protected`/`public` anywhere in
  // this class's own real source. See this file's own top comment for
  // why no MRB_SET_INSTANCE_TT call belongs here.
  mrb_define_private_method(M, event_command, "initialize",
                            LCF__EventCommand_initialize, MRB_ARGS_REQ(4));
  mrb_define_method(M, event_command, "param", LCF__EventCommand_param,
                    MRB_ARGS_REQ(1));

  // LCF::MoveCommand (docs/adr/0139's own follow-up): one decoded RPG2000
  // move-route command (a command id plus optional string/integer
  // parameters), mruby-lcf/mrblib/lcf.rb. Its own #initialize is the ONLY
  // real bytecode-defined method on this class at all (attr_reader
  // :command_id, :parameter_string, :parameter_a, :parameter_b,
  // :parameter_c stays native/uncompiled, as always), and it compiles
  // clean: 5 purely mandatory arguments, no super, no block.
  //
  // Stale as of the natively_exposed?/drop_unsafe_embeddings fix a few
  // rounds up (docs/adr/0139's own eighth-severe-bug follow-up, the same
  // one that stopped Game::State/Map/ChipSet/Switches and this gem's own
  // LCF::EventCommand from embedding): this class's own bare
  // `attr_reader :command_id, ..., :parameter_a, :parameter_b,
  // :parameter_c` is the EXACT same shape that fix exists to catch, and a
  // re-run of the real whole-program diagnostic against the *current*
  // bc2cpp.rb (this round's own dedicated follow-up sweep) confirms
  // LCF::MoveCommand no longer appears in bc2cpp's own "classes needing
  // MRB_SET_INSTANCE_TT" diagnostic at all -- the comment this replaced
  // (claiming a real LCF__MoveCommand_ivars RData struct and a
  // mrb_data_init call) described an earlier bc2cpp.rb, before that fix
  // landed, and was simply never re-checked against it even though the
  // fix's own round touched this very file. The regenerated
  // #initialize body now writes @command_id/@parameter_a/@parameter_b/
  // @parameter_c/@parameter_string via plain mrb_iv_set, exactly like
  // every other (non-embedding) compiled #initialize in this gem --
  // confirmed directly against the real generated lcf_compiled_gen.cpp,
  // not assumed. So no MRB_SET_INSTANCE_TT call belongs in this class's
  // own registration block below (removed here): leaving the stale call
  // in place tagged every real LCF::MoveCommand instance MRB_TT_DATA/
  // MRB_TT_CDATA with no compiled code ever allocating or reading its
  // RData payload (data/type always NULL) -- confirmed harmless at the
  // mruby-core level (mrb_iv_get/mrb_iv_set, #dup/#clone's mrb_iv_copy,
  // and the GC's own mark/free paths all treat MRB_TT_CDATA the same as
  // MRB_TT_OBJECT for ivars, and free-side checks `type &&
  // type->dfree` before ever touching it), so this was drift, not a
  // second live embedding bug -- but drift this project's own established
  // discipline (see this file's own EventCommand comment above, and
  // mruby-rpg2k-compiled/src/register.cxx's top comment) always corrects
  // rather than leaves for the next reader to trust blindly. #initialize
  // is forced private by mruby's own interpreter regardless of source
  // (mrb_define_method_raw's own special case for the name), so this
  // still uses mrb_define_private_method, not mrb_define_method --
  // confirmed directly against the real diagnostic's own `== compiled
  // entry points ==` listing, which flags it accordingly.
  RClass* move_command = mrb_class_get_under(M, lcf, "MoveCommand");
  mrb_define_private_method(M, move_command, "initialize",
                            LCF__MoveCommand_initialize, MRB_ARGS_REQ(5));

  // LCF::Array1D: 5 of its own 11 real bytecode-defined methods compile
  // clean and are registered below -- all public, confirmed directly
  // against the real diagnostic's own `== compiled entry points ==`
  // listing, none flagged private (unlike every compiled #initialize in
  // this file, #[]/#key?/#int16_values/#delete/#[]= carry no source-level
  // `private` and are not mruby's own always-private #initialize special
  // case). #initialize, #to_lcf, #method_missing, #respond_to_missing?
  // and #sym2idx stay interpreted -- see this file's own top comment and
  // tools/bc2cpp/compiled_gems.rb's own LCF::Array1D comment for exactly
  // why each one does. No MRB_SET_INSTANCE_TT call belongs here: this
  // class never appears in bc2cpp's own "classes needing
  // MRB_SET_INSTANCE_TT" diagnostic (@data/@schema are never Fixnum/
  // Symbol).
  RClass* array1d = mrb_class_get_under(M, lcf, "Array1D");
  mrb_define_method(M, array1d, "[]", LCF__Array1D___, MRB_ARGS_REQ(1));
  mrb_define_method(M, array1d, "key?", LCF__Array1D_key_, MRB_ARGS_REQ(1));
  mrb_define_method(M, array1d, "int16_values", LCF__Array1D_int16_values,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, array1d, "delete", LCF__Array1D_delete, MRB_ARGS_REQ(1));
  mrb_define_method(M, array1d, "[]=", LCF__Array1D____, MRB_ARGS_REQ(2));

  // LCF::Array2D: only 2 of its own 6 real bytecode-defined methods
  // compile clean and are registered below -- both public, confirmed
  // directly against the real diagnostic's own `== compiled entry
  // points ==` listing. #initialize, #each, #to_lcf, and the private
  // #read_row_bytes all stay interpreted -- see this file's own top
  // comment and tools/bc2cpp/compiled_gems.rb's own LCF::Array2D comment
  // for exactly why each one does. No MRB_SET_INSTANCE_TT call belongs
  // here: this class never appears in bc2cpp's own "classes needing
  // MRB_SET_INSTANCE_TT" diagnostic (@data/@schema are never Fixnum/
  // Symbol).
  RClass* array2d = mrb_class_get_under(M, lcf, "Array2D");
  mrb_define_method(M, array2d, "[]", LCF__Array2D___, MRB_ARGS_REQ(1));
  mrb_define_method(M, array2d, "[]=", LCF__Array2D____, MRB_ARGS_REQ(2));

  // LCF::File#[]/#[]= (mruby-lcf/mrblib/lcf_file.rb: `def [] idx ; @root[idx]
  // end` / `def []= idx, value ; @root[idx] = value end`) were flagged as a
  // pre-existing gap by this project's own LCF::Array1D follow-up
  // (docs/adr/0139): the `#error unhandled opcode BLOCK`-style diagnostics
  // that keep #initialize/#method_missing/#respond_to_missing?/#save_to
  // interpreted (see this file's own top comment) never applied to these
  // two -- both #[] and #[]= compile clean today, confirmed directly
  // against the real `== compiled entry points ==` listing, but had simply
  // never been wired into this registration block despite that. Both
  // compile to the exact same generic array/hash/POLY-`mrb_funcall`-
  // fallback shape LCF::Array1D's/LCF::Sections's own already-registered
  // `#[]`/`#[]=` use (an `@root[idx]`/`@root[idx] = value` GETIDX/SETIDX
  // against whatever @root's own real runtime class is -- LCF::File's own
  // #initialize, mruby-lcf/mrblib/lcf_file.rb, always sets @root to either
  // an LCF::Sections or an LCF.const_get(schema[:type]) instance, never an
  // actual Array/Hash, so the fallback `mrb_funcall(M, r3, "[]"/"[]=", ...)`
  // branch always fires and dispatches dynamically to that instance's own
  // real method -- exactly as safe as every other already-shipped GETIDX/
  // SETIDX fallback in this codebase, needing no devirtualization of
  // `@root` itself). Both are public (no source-level `private`, confirmed
  // against the diagnostic's own listing, which carries no `[private -- ...]`
  // tag for either). Registered below to close the gap.
  mrb_define_method(M, file, "[]", LCF__File___, MRB_ARGS_REQ(1));
  mrb_define_method(M, file, "[]=", LCF__File____, MRB_ARGS_REQ(2));
  mrb_define_method(M, file, "key?", LCF__File_key_, MRB_ARGS_REQ(1));
  mrb_define_method(M, file, "to_lcf", LCF__File_to_lcf, MRB_ARGS_NONE());
  mrb_define_method(M, file, "header", LCF__File_header, MRB_ARGS_NONE());
  mrb_define_method(M, file, "schema", LCF__File_schema, MRB_ARGS_NONE());
  mrb_define_method(M, file, "terminate_root?", LCF__File_terminate_root_,
                    MRB_ARGS_NONE());

  mrb_define_method(M, database, "header", LCF__Database_header,
                    MRB_ARGS_NONE());
  mrb_define_method(M, database, "schema", LCF__Database_schema,
                    MRB_ARGS_NONE());
  mrb_define_method(M, database, "rpg2003?", LCF__Database_rpg2003_,
                    MRB_ARGS_NONE());
  mrb_define_method(M, database, "maker", LCF__Database_maker, MRB_ARGS_NONE());

  mrb_define_method(M, map_tree, "header", LCF__MapTree_header,
                    MRB_ARGS_NONE());
  mrb_define_method(M, map_tree, "schema", LCF__MapTree_schema,
                    MRB_ARGS_NONE());

  mrb_define_method(M, map_unit, "header", LCF__MapUnit_header,
                    MRB_ARGS_NONE());
  mrb_define_method(M, map_unit, "schema", LCF__MapUnit_schema,
                    MRB_ARGS_NONE());
  mrb_define_method(M, map_unit, "terminate_root?",
                    LCF__MapUnit_terminate_root_, MRB_ARGS_NONE());

  mrb_define_method(M, save_data, "header", LCF__SaveData_header,
                    MRB_ARGS_NONE());
  mrb_define_method(M, save_data, "schema", LCF__SaveData_schema,
                    MRB_ARGS_NONE());
}

extern "C" void mrb_mruby_lcf_compiled_gem_final(mrb_state*) {}
