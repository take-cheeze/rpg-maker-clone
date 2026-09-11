// Swaps AOT-compiled C++ bodies in for a hand-picked, provably-safe subset
// of LCF::File/Database/MapTree/MapUnit/SaveData's own bytecode methods
// (docs/adr/0139), plus LCF::MoveCommand#initialize and
// LCF::EventCommand#initialize/#param (docs/adr/0139's own follow-ups,
// mruby-lcf/mrblib/lcf.rb). mruby-lcf (this gem's own add_dependency)
// has already run its full gem init -- C hook *and* mrblib -- by the
// time this gem's own init runs (mrbgems.rake sequences gem_funcs[] in
// dependency order, each entry running its complete init before the next
// gem's own init starts), so every class fetched below is guaranteed to
// already exist.
//
// Every method NOT registered here (LCF::File#initialize, #[], #[]=,
// #method_missing, #respond_to_missing?, #save_to, ...) is untouched:
// mruby-lcf's own mrblib already defined it moments ago, and it keeps
// running on the ordinary interpreted bytecode path -- the documented
// fallback for anything bc2cpp couldn't safely compile.
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
  // clean: 5 purely mandatory arguments, no super, no block. Confirmed
  // directly against the real generated output, not just the class's own
  // pre-existing `# bc2cpp: (fixnum, , fixnum, fixnum, fixnum)` magic
  // comment: LCF::MoveCommand appears in bc2cpp's own "classes needing
  // MRB_SET_INSTANCE_TT" diagnostic, and the generated #initialize body
  // really does call mrb_data_init before any other statement, guarded
  // the same way every other embedded ivar write already is
  // (mrb_integer_p + mrb_raise on a non-Integer value). @command_id,
  // @parameter_a, @parameter_b and @parameter_c (all provably Fixnum) are
  // real fields on a new LCF__MoveCommand_ivars RData struct;
  // @parameter_string (a String, never Fixnum/Symbol) correctly stays off
  // that struct and on the ordinary dynamic iv_tbl, via a plain
  // mrb_iv_set -- confirmed directly against the generated code, not
  // assumed from its type. #initialize is forced private by mruby's own
  // interpreter regardless of source (mrb_define_method_raw's own
  // special case for the name), so this uses
  // mrb_define_private_method, not mrb_define_method -- confirmed
  // directly against the real diagnostic's own `== compiled entry
  // points ==` listing, which flags it accordingly.
  RClass* move_command = mrb_class_get_under(M, lcf, "MoveCommand");
  MRB_SET_INSTANCE_TT(move_command, MRB_TT_DATA);
  mrb_define_private_method(M, move_command, "initialize",
                            LCF__MoveCommand_initialize, MRB_ARGS_REQ(5));

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
