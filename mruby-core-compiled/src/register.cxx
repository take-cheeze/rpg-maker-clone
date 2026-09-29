// Installs the compiled bodies of mruby's own Ruby methods (docs/adr/0264).
// Registration is generated: bc2cpp_register_owner_methods defines every entry
// that compiled clean, with the visibility and aspec its entry wrapper reads,
// so this file names no method. Every gem whose mrblib defines one of them
// (this gem's dependencies) has already loaded its bytecode, which this
// replaces.
#include <mruby.h>
#include <mruby/class.h>

#include "core_compiled_gen.cpp"

extern "C" void mrb_mruby_core_compiled_gem_init(mrb_state* M) {
  bc2cpp_set_instance_tts(M);
  bc2cpp_register_owner_methods(M);
}

extern "C" void mrb_mruby_core_compiled_gem_final(mrb_state*) {}
