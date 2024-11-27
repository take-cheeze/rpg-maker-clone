#include <mruby.h>

#include <uni_algo/norm.h>

namespace {
mrb_value to_nfd(mrb_state* M, mrb_value self) {
  const char* ptr;
  mrb_int len;
  mrb_get_args(M, "s", &ptr, &len);
  std::string nfd = una::norm::to_nfd_utf8(std::string_view(ptr, len));
  return mrb_str_new(M, nfd.data(), nfd.size());
}
}  // namespace

extern "C" void mrb_mruby_rgss_gem_init(mrb_state* M) {
  RClass* m = mrb_define_module(M, "RGSS");
  RClass* bmp = mrb_define_class_under(M, m, "Bitmap", M->object_class);
  mrb_define_module_function(M, m, "to_nfd", to_nfd, MRB_ARGS_REQ(1));
}

extern "C" void mrb_mruby_rgss_gem_final(mrb_state* mrb) {}
