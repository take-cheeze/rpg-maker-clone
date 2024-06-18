#include <mruby.h>
#include <cstdlib>
#include <memory>

#include <unistd.h>

#include <iostream>

#include <lvgl.h>

#include <gflags/gflags.h>

DEFINE_int64(timeout_ms, -1, "timeout to exit");

int main(int argc, char** argv) {
  gflags::ParseCommandLineFlags(&argc, &argv, true);

  std::shared_ptr<mrb_state> M(mrb_open(), mrb_close);

  lv_init();

  std::shared_ptr<lv_display_t> display(lv_sdl_window_create(320, 240), [](lv_display_t*) { lv_sdl_quit(); });
  std::shared_ptr<lv_group_t> group(lv_group_create(), lv_group_delete);
  lv_group_set_default(group.get());

  lv_obj_t* win = lv_win_create(lv_screen_active());
  lv_win_add_title(win, "test");

  const uint32_t start = lv_tick_get();

  while (true) {
    if (FLAGS_timeout_ms > 0 && (lv_tick_get() - start) > FLAGS_timeout_ms) {
      break;
    }

    lv_timer_handler();
    lv_delay_ms(1000 / 60);
  }

  return EXIT_SUCCESS;
}
