// Installs the compiled bodies of mruby's own Ruby methods. Everything here is
// generated (tools/bc2cpp/codegen_emit.rb): bc2cpp_gem_init
// defines every entry that compiled clean, with the visibility and aspec its
// entry wrapper reads, so this file names no method. Every gem whose mrblib
// defines one of them (this gem's dependencies) has already loaded its
// bytecode, which this replaces.
#include <mruby.h>
#include <mruby/class.h>

#include "core_compiled_gen.cpp"

extern "C" void mrb_mruby_core_compiled_gem_init(mrb_state* M) {
  bc2cpp_gem_init(M);
}

extern "C" void mrb_mruby_core_compiled_gem_final(mrb_state*) {
  bc2cpp_gem_final();
}
