// Test-only hook for mruby-rgss's mrbtest build (ADR 0263): RGSS::DirectProbe
// calls a generated `rgss::*_direct` entry point by name, so
// test/native_direct.rb can run a split binding and its direct entry point on
// the same objects and compare. Never compiled into the game.
#include <mruby.h>
#include <mruby/array.h>
#include <mruby/class.h>
#include <mruby/string.h>

#include "rgss_construct.hxx"

#include <cstring>

namespace {

const char* probe_str_ptr(mrb_state* M, mrb_value v) {
  return RSTRING_PTR(mrb_ensure_string_type(M, v));
}

mrb_int probe_str_len(mrb_state* M, mrb_value v) {
  return RSTRING_LEN(mrb_ensure_string_type(M, v));
}

struct ProbeEntry {
  const char* name;
  mrb_int argc;
  mrb_value (*call)(mrb_state*, mrb_value, mrb_value*);
};

const ProbeEntry kProbes[] = {
#include "native_direct_probe.inc"
};

const ProbeEntry* find_probe(const char* name) {
  for (const ProbeEntry& e : kProbes)
    if (std::strcmp(e.name, name) == 0)
      return &e;
  return nullptr;
}

// RGSS::DirectProbe.call(name, self, *args)
mrb_value probe_call(mrb_state* M, mrb_value) {
  const char* name;
  mrb_value self;
  const mrb_value* argv;
  mrb_int argc;
  mrb_get_args(M, "zo*", &name, &self, &argv, &argc);
  const ProbeEntry* e = find_probe(name);
  if (!e)
    mrb_raisef(M, mrb_exc_get_id(M, MRB_ERROR_SYM(ArgumentError)),
               "no direct entry point %s", name);
  if (argc != e->argc)
    mrb_raisef(M, mrb_exc_get_id(M, MRB_ERROR_SYM(ArgumentError)),
               "%s takes %d arguments (%d given)", name, (int)e->argc,
               (int)argc);
  mrb_value args[8] = {};
  for (mrb_int i = 0; i < argc && i < 8; ++i)
    args[i] = argv[i];
  return e->call(M, self, args);
}

// RGSS::DirectProbe.names
mrb_value probe_names(mrb_state* M, mrb_value) {
  mrb_value out = mrb_ary_new(M);
  for (const ProbeEntry& e : kProbes)
    mrb_ary_push(M, out, mrb_str_new_cstr(M, e.name));
  return out;
}

}  // namespace

extern "C" void mrb_mruby_rgss_gem_test(mrb_state* M) {
  RClass* rgss = mrb_module_get(M, "RGSS");
  RClass* probe = mrb_define_module_under(M, rgss, "DirectProbe");
  mrb_define_module_function(M, probe, "call", probe_call,
                             MRB_ARGS_REQ(2) | MRB_ARGS_REST());
  mrb_define_module_function(M, probe, "names", probe_names, MRB_ARGS_NONE());
}
