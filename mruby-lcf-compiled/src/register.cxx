// Swaps AOT-compiled C++ bodies in for a hand-picked, provably-safe subset
// of LCF::File/Database/MapTree/MapUnit/SaveData's own bytecode methods
// (docs/adr/0139). mruby-lcf (this gem's own add_dependency) has already
// run its full gem init -- C hook *and* mrblib -- by the time this gem's
// own init runs (mrbgems.rake sequences gem_funcs[] in dependency order,
// each entry running its complete init before the next gem's own init
// starts), so every class fetched below is guaranteed to already exist.
//
// Every method NOT registered here (#initialize, #[], #[]=,
// #method_missing, #respond_to_missing?, #save_to, ...) is untouched:
// mruby-lcf's own mrblib/lcf_file.rb already defined it moments ago, and
// it keeps running on the ordinary interpreted bytecode path -- the
// documented fallback for anything bc2cpp couldn't safely compile.
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
