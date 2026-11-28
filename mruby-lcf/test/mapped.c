/* MAPPED_LCF test helpers (lcf_test.rb): bytes that stay put, as a platform's
 * mapped file's do (include/lcf_file_map.h). */
#include <stdlib.h>
#include <string.h>

#include <mruby.h>
#include <mruby/class.h>
#include <mruby/string.h>

#include "lcf_file_map.h"

#define TEST_PATH "/mapped/test.lmu"

static const char* g_bytes;
static size_t g_len;

/* A copy of `s` that is never freed. */
static const char* keep(mrb_state* mrb, mrb_value s) {
  char* p = (char*)malloc(RSTRING_LEN(s) + 1);
  if (!p)
    mrb_raise(mrb, E_RUNTIME_ERROR, "out of memory");
  memcpy(p, RSTRING_PTR(s), RSTRING_LEN(s));
  return p;
}

/* LCF::Test.static_bytes(s): a NOFREE String over a copy of s's bytes. */
static mrb_value static_bytes(mrb_state* mrb, mrb_value self) {
  mrb_value s;
  mrb_get_args(mrb, "S", &s);
  return mrb_str_new_static(mrb, keep(mrb, s), RSTRING_LEN(s));
}

static const void* test_map(const char* path, size_t* len) {
  if (!g_bytes || strcmp(path, TEST_PATH) != 0)
    return NULL;
  *len = g_len;
  return g_bytes;
}

/* LCF::Test.map(s): LCF.mapped_file(TEST_PATH) answers s's bytes from now on. */
static mrb_value map_bytes(mrb_state* mrb, mrb_value self) {
  mrb_value s;
  mrb_get_args(mrb, "S", &s);
  g_bytes = keep(mrb, s);
  g_len = RSTRING_LEN(s);
  lcf_set_file_map(test_map);
  return mrb_str_new_lit(mrb, TEST_PATH);
}

/* LCF::Test.in_use?: whether anything still points into the bytes the last
 * LCF::Test.map installed (lcf_mapped_in_use). */
static mrb_value in_use(mrb_state* mrb, mrb_value self) {
  lcf_mapped_range r = {g_bytes, g_len};
  bool used = true;
  lcf_mapped_in_use(mrb, &r, 1, &used);
  return mrb_bool_value(used);
}

void mrb_mruby_lcf_gem_test(mrb_state* mrb) {
  struct RClass* lcf = mrb_module_get(mrb, "LCF");
  struct RClass* t = mrb_define_module_under(mrb, lcf, "Test");
  mrb_define_module_function(mrb, t, "static_bytes", static_bytes,
                             MRB_ARGS_REQ(1));
  mrb_define_module_function(mrb, t, "map", map_bytes, MRB_ARGS_REQ(1));
  mrb_define_module_function(mrb, t, "in_use?", in_use, MRB_ARGS_NONE());
}
