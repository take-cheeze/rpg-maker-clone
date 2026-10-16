// Host driver for the headless game run: a placeholder LVGL display (the LVGL calls are stubs), then one Ruby file.
#include <mruby.h>
#include <mruby/compile.h>
#include <cstdio>
#include <fstream>
#include <iterator>
#include <string>

struct _lv_display_t;
extern "C" void rgss_set_display(mrb_state* M, _lv_display_t* d);

int main(int argc, char** argv) {
  if (argc != 2) { std::fprintf(stderr, "usage: %s file.rb\n", argv[0]); return 2; }
  std::ifstream in(argv[1], std::ios::binary);
  std::string src((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
  mrb_state* M = mrb_open();
  if (!M) { std::fprintf(stderr, "mrb_open failed\n"); return 1; }
  static char placeholder_display[64];
  rgss_set_display(M, reinterpret_cast<_lv_display_t*>(placeholder_display));
  mrb_load_string(M, src.c_str());
  int rc = 0;
  if (M->exc) { mrb_print_error(M); rc = 1; }
  mrb_close(M);
  return rc;
}
