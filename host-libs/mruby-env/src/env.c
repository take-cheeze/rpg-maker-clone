/*
 * ENV: the process environment as a plain object with CRuby's methods for it. Values are strings; a missing name is
 * nil from [] and KeyError from fetch without a default. Assigning nil removes the variable.
 */
#include <mruby.h>
#include <mruby/hash.h>
#include <mruby/string.h>
#include <mruby/error.h>
#include <stdlib.h>
#include <string.h>

extern char **environ;

static mrb_value
env_aref(mrb_state *mrb, mrb_value self)
{
  mrb_value name;
  mrb_get_args(mrb, "S", &name);
  const char *value = getenv(mrb_string_cstr(mrb, name));
  return value ? mrb_str_new_cstr(mrb, value) : mrb_nil_value();
}

static mrb_value
env_aset(mrb_state *mrb, mrb_value self)
{
  mrb_value name, value;
  mrb_get_args(mrb, "So", &name, &value);
  if (mrb_nil_p(value)) {
    unsetenv(mrb_string_cstr(mrb, name));
  } else {
    if (setenv(mrb_string_cstr(mrb, name), mrb_string_cstr(mrb, mrb_ensure_string_type(mrb, value)), 1) != 0) {
      mrb_sys_fail(mrb, "setenv");
    }
  }
  return value;
}

static mrb_value
env_fetch(mrb_state *mrb, mrb_value self)
{
  mrb_value name, fallback = mrb_undef_value();
  mrb_int argc = mrb_get_args(mrb, "S|o", &name, &fallback);
  const char *value = getenv(mrb_string_cstr(mrb, name));
  if (value) return mrb_str_new_cstr(mrb, value);
  if (argc == 2) return fallback;

  mrb_value message = mrb_str_new_cstr(mrb, "key not found: \"");
  mrb_str_cat_str(mrb, message, name);
  mrb_str_cat_cstr(mrb, message, "\"");
  struct RClass *key_error = mrb_class_get(mrb, "KeyError");
  mrb_exc_raise(mrb, mrb_obj_new(mrb, key_error, 1, &message));
  return mrb_nil_value();
}

static mrb_value
env_key_p(mrb_state *mrb, mrb_value self)
{
  mrb_value name;
  mrb_get_args(mrb, "S", &name);
  return mrb_bool_value(getenv(mrb_string_cstr(mrb, name)) != NULL);
}

static mrb_value
env_delete(mrb_state *mrb, mrb_value self)
{
  mrb_value name;
  mrb_get_args(mrb, "S", &name);
  const char *old = getenv(mrb_string_cstr(mrb, name));
  mrb_value result = old ? mrb_str_new_cstr(mrb, old) : mrb_nil_value();
  unsetenv(mrb_string_cstr(mrb, name));
  return result;
}

static mrb_value
env_to_h(mrb_state *mrb, mrb_value self)
{
  mrb_value hash = mrb_hash_new(mrb);
  for (char **entry = environ; entry && *entry; entry++) {
    const char *eq = strchr(*entry, '=');
    if (!eq) continue;
    mrb_value key = mrb_str_new(mrb, *entry, (mrb_int)(eq - *entry));
    mrb_hash_set(mrb, hash, key, mrb_str_new_cstr(mrb, eq + 1));
  }
  return hash;
}

void
mrb_mruby_env_gem_init(mrb_state *mrb)
{
  mrb_value env = mrb_obj_new(mrb, mrb->object_class, 0, NULL);
  mrb_define_const(mrb, mrb->object_class, "ENV", env);
  struct RClass *sc = mrb_singleton_class_ptr(mrb, env);
  mrb_define_method(mrb, sc, "[]", env_aref, MRB_ARGS_REQ(1));
  mrb_define_method(mrb, sc, "[]=", env_aset, MRB_ARGS_REQ(2));
  mrb_define_method(mrb, sc, "fetch", env_fetch, MRB_ARGS_REQ(1) | MRB_ARGS_OPT(1));
  mrb_define_method(mrb, sc, "key?", env_key_p, MRB_ARGS_REQ(1));
  mrb_define_method(mrb, sc, "has_key?", env_key_p, MRB_ARGS_REQ(1));
  mrb_define_method(mrb, sc, "delete", env_delete, MRB_ARGS_REQ(1));
  mrb_define_method(mrb, sc, "to_h", env_to_h, MRB_ARGS_NONE());
}

void
mrb_mruby_env_gem_final(mrb_state *mrb)
{
}
