// Host entry points into the game's Ruby: bc2cpp_entry_<Owner>_<name>(M, self,
// args...). See docs/bc2cpp-entry-points.md.
//
// A host calls these instead of mrb_funcall(M, game, "main_loop", 0) and the
// like. They keep mrb_funcall's contract: on a raise M->exc holds the exception
// and the exception object is returned.
//
// In a closed-world build (RPGMAKER_BC2CPP=1: psp, wio, maix,
// scripts/bc2cpp/trace_host.bash) bc2cpp writes <gem>_compiled_entry.h into the
// build's include directory. Included here, it calls the compiled _impl
// directly for every entry it proved (BC2CPP_ENTRY_<Owner>_<name> is 1), after
// checking the receiver's class is exactly the owner. Everywhere else (the
// desktop, wasm and Android builds, which run plain mruby) the fallbacks below
// call by name. Define BC2CPP_ENTRY_BY_NAME to force the by-name forms.
//
// The entry list is tools/bc2cpp/codegen_entry_header.rb ENTRY_POINTS, plus
// HOST_ONLY_ENTRY_POINTS (RPGXP/RPGVX, which no build compiles, so they are
// always by name); scripts/bc2cpp/entry_header_check.rb keeps the fallbacks
// below in step with both. bc2cpp_entry_<Owner>_new(M, argc, argv) is
// mrb_obj_new(M, <Owner>, argc, argv).
#pragma once

#include <mruby.h>

#if !defined(BC2CPP_ENTRY_BY_NAME) && defined(__has_include)
#if __has_include(<rpg2k_compiled_entry.h>)
#include <rpg2k_compiled_entry.h>
#endif
#endif

#ifndef BC2CPP_ENTRY_RPG2k_main_loop
#define BC2CPP_ENTRY_RPG2k_main_loop 0
static inline mrb_value bc2cpp_entry_RPG2k_main_loop(mrb_state* M,
                                                     mrb_value self) {
  return mrb_funcall(M, self, "main_loop", 0);
}
#endif

#ifndef BC2CPP_ENTRY_RPG2k_start
#define BC2CPP_ENTRY_RPG2k_start 0
static inline mrb_value bc2cpp_entry_RPG2k_start(mrb_state* M, mrb_value self) {
  return mrb_funcall(M, self, "start", 0);
}
#endif

#ifndef BC2CPP_ENTRY_RPG2k_current_scene_name
#define BC2CPP_ENTRY_RPG2k_current_scene_name 0
static inline mrb_value bc2cpp_entry_RPG2k_current_scene_name(mrb_state* M,
                                                              mrb_value self) {
  return mrb_funcall(M, self, "current_scene_name", 0);
}
#endif

#ifndef BC2CPP_ENTRY_RPG2k_new
#define BC2CPP_ENTRY_RPG2k_new 0
static inline mrb_value bc2cpp_entry_RPG2k_new(mrb_state* M,
                                               mrb_int argc,
                                               const mrb_value* argv) {
  return mrb_obj_new(M, mrb_class_get(M, "RPG2k"), argc, argv);
}
#endif

// RPGXP / RPGVX (app/psp): by name in every build; see HOST_ONLY_ENTRY_POINTS.
#ifndef BC2CPP_ENTRY_RPGXP_new
#define BC2CPP_ENTRY_RPGXP_new 0
static inline mrb_value bc2cpp_entry_RPGXP_new(mrb_state* M,
                                               mrb_int argc,
                                               const mrb_value* argv) {
  return mrb_obj_new(M, mrb_class_get(M, "RPGXP"), argc, argv);
}
#endif

#ifndef BC2CPP_ENTRY_RPGXP_main_loop
#define BC2CPP_ENTRY_RPGXP_main_loop 0
static inline mrb_value bc2cpp_entry_RPGXP_main_loop(mrb_state* M,
                                                     mrb_value self) {
  return mrb_funcall(M, self, "main_loop", 0);
}
#endif

#ifndef BC2CPP_ENTRY_RPGXP_current_scene_name
#define BC2CPP_ENTRY_RPGXP_current_scene_name 0
static inline mrb_value bc2cpp_entry_RPGXP_current_scene_name(mrb_state* M,
                                                              mrb_value self) {
  return mrb_funcall(M, self, "current_scene_name", 0);
}
#endif

#ifndef BC2CPP_ENTRY_RPGVX_new
#define BC2CPP_ENTRY_RPGVX_new 0
static inline mrb_value bc2cpp_entry_RPGVX_new(mrb_state* M,
                                               mrb_int argc,
                                               const mrb_value* argv) {
  return mrb_obj_new(M, mrb_class_get(M, "RPGVX"), argc, argv);
}
#endif

#ifndef BC2CPP_ENTRY_RPGVX_main_loop
#define BC2CPP_ENTRY_RPGVX_main_loop 0
static inline mrb_value bc2cpp_entry_RPGVX_main_loop(mrb_state* M,
                                                     mrb_value self) {
  return mrb_funcall(M, self, "main_loop", 0);
}
#endif

#ifndef BC2CPP_ENTRY_RPGVX_current_scene_name
#define BC2CPP_ENTRY_RPGVX_current_scene_name 0
static inline mrb_value bc2cpp_entry_RPGVX_current_scene_name(mrb_state* M,
                                                              mrb_value self) {
  return mrb_funcall(M, self, "current_scene_name", 0);
}
#endif
