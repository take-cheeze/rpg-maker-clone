#include <mruby.h>

extern "C" void mrb_mruby_rgss_gem_init(mrb_state* M) {
    RClass* m = mrb_define_module(M, "RGSS");
    RClass* bmp = mrb_define_class_under(M, m, "Bitmap", M->object_class);
}

extern "C" void mrb_mruby_rgss_gem_final(mrb_state* mrb) {
}