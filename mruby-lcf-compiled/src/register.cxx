// Swaps AOT-compiled C++ bodies in for a hand-picked, provably-safe subset
// of LCF::File/Database/MapTree/MapUnit/SaveData's own bytecode methods
// (docs/adr/0139), plus LCF::MoveCommand#initialize (docs/adr/0139's own
// follow-up, mruby-lcf/mrblib/lcf.rb). mruby-lcf (this gem's own
// add_dependency) has already run its full gem init -- C hook *and*
// mrblib -- by the time this gem's own init runs (mrbgems.rake sequences
// gem_funcs[] in dependency order, each entry running its complete init
// before the next gem's own init starts), so every class fetched below is
// guaranteed to already exist.
//
// Every method NOT registered here (LCF::File#initialize, #[], #[]=,
// #method_missing, #respond_to_missing?, #save_to, ...) is untouched:
// mruby-lcf's own mrblib already defined it moments ago, and it keeps
// running on the ordinary interpreted bytecode path -- the documented
// fallback for anything bc2cpp couldn't safely compile.
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
