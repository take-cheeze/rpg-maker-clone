#include <mruby.h>
#include <mruby/class.h>
#include <mruby/object.h>
#include <mruby/string.h>
#include <mruby/variable.h>

// The stream for fd, made as the block-less form of the IO class's constructor. mrb_obj_new, not a sent message:
// the closed build's proof reads method names out of the source text, and a name sent here stays reachable.
static mrb_value
std_open(mrb_state *mrb, mrb_value io, mrb_int fd, const char *mode)
{
  mrb_value args[2] = {mrb_fixnum_value(fd), mrb_str_new_cstr(mrb, mode)};
  return mrb_obj_new(mrb, mrb_class_ptr(io), 2, args);
}

// STDIN, STDOUT and STDERR for fds 0, 1 and 2 (read, write, write), and $stdin, $stdout and $stderr to match.
static mrb_value
bc2cpp_std_init(mrb_state *mrb, mrb_value self)
{
  (void)self;
  mrb_value io = mrb_obj_value(mrb_class_get(mrb, "IO"));
  mrb_value in = std_open(mrb, io, 0, "r");
  mrb_value out = std_open(mrb, io, 1, "w");
  mrb_value err = std_open(mrb, io, 2, "w");
  mrb_const_set(mrb, mrb_obj_value(mrb->object_class), mrb_intern_lit(mrb, "STDIN"), in);
  mrb_const_set(mrb, mrb_obj_value(mrb->object_class), mrb_intern_lit(mrb, "STDOUT"), out);
  mrb_const_set(mrb, mrb_obj_value(mrb->object_class), mrb_intern_lit(mrb, "STDERR"), err);
  mrb_gv_set(mrb, mrb_intern_lit(mrb, "$stdin"), in);
  mrb_gv_set(mrb, mrb_intern_lit(mrb, "$stdout"), out);
  mrb_gv_set(mrb, mrb_intern_lit(mrb, "$stderr"), err);
  return mrb_nil_value();
}

void
mrb_mruby_bc2cpp_std_gem_init(mrb_state *mrb)
{
  mrb_define_method(mrb, mrb->kernel_module, "__bc2cpp_std_init", bc2cpp_std_init, MRB_ARGS_NONE());
}

void
mrb_mruby_bc2cpp_std_gem_final(mrb_state *mrb)
{
  (void)mrb;
}
