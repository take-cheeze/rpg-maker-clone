
#include <cstdlib>
#include <filesystem>
#include <memory>

#include <lvgl.h>
#include <mruby.h>
#include <mruby/variable.h>

#include <gflags/gflags.h>
#include <glog/logging.h>

#define STB_IMAGE_IMPLEMENTATION
#include <stb_image.h>

DEFINE_int64(timeout_ms, -1, "timeout to exit");
DEFINE_int64(width, 320, "width of the window");
DEFINE_int64(height, 240, "height of the window");
DEFINE_string(game_dir, "", "Game directory");

namespace {

namespace fs = std::filesystem;

void* lvallocf(mrb_state* M, void* p, size_t s, void* ud) {
  if (s == 0) {
    lv_free(p);
    return nullptr;
  } else if (p) {
    return lv_realloc(p, s);
  } else {
    return lv_malloc(s);
  }
}

}  // namespace

int main(int argc, char** argv) {
  gflags::ParseCommandLineFlags(&argc, &argv, true);
  if (FLAGS_game_dir.empty()) {
    FLAGS_game_dir = fs::current_path();
  }
  google::InitGoogleLogging(argv[0]);

  lv_init();

  std::shared_ptr<lv_display_t> display(
      lv_sdl_window_create(FLAGS_width, FLAGS_height),
      [](lv_display_t*) { lv_sdl_quit(); });
  CHECK(display);
  lv_sdl_window_set_resizeable(display.get(), false);

  std::shared_ptr<lv_obj_t> canvas(
      lv_canvas_create(lv_display_get_screen_active(display.get())),
      lv_obj_delete);
  std::shared_ptr<lv_draw_buf_t> draw_buf(
      lv_draw_buf_create(FLAGS_width, FLAGS_height, LV_COLOR_FORMAT_RGB888, 0),
      lv_draw_buf_destroy);
  CHECK(draw_buf);
  lv_canvas_set_draw_buf(canvas.get(), draw_buf.get());

  const uint32_t start = lv_tick_get();

  lv_draw_rect_dsc_t rect;
  lv_draw_rect_dsc_init(&rect);
  rect.bg_color = LV_COLOR_MAKE(255, 0, 0);

  std::shared_ptr<mrb_state> mrb(mrb_open_allocf(lvallocf, nullptr), mrb_close);
  mrb_state* M = mrb.get();
  CHECK(!M->exc);

  int frame = 0;

  // stbi__png_transparent_palette = true;
  stbi__png_to_bgr_palette = true;
  std::string title_path = FLAGS_game_dir + "/Title/Nepheshel_logo.png";
  int w, h, c;
  std::shared_ptr<uint8_t> img(stbi_load(title_path.c_str(), &w, &h, &c,
                                         stbi__png_transparent_palette ? 4 : 3),
                               stbi_image_free);
  CHECK(img) << stbi_failure_reason();
  // LOG(INFO) << "w: " << w << ", h: " << h << ", c: " << c << std::endl;

  std::shared_ptr<lv_obj_t> title(lv_canvas_create(canvas.get()),
                                  lv_obj_delete);
  lv_canvas_set_buffer(
      title.get(), img.get(), w, h,
      c == 3 ? LV_COLOR_FORMAT_RGB888 : LV_COLOR_FORMAT_ARGB8888);

  mrb_const_set(M, mrb_obj_value(M->object_class),
                mrb_intern_lit(M, "GAME_DIR"),
                mrb_str_new_cstr(M, FLAGS_game_dir.c_str()));
  CHECK(!M->exc);

  mrb_value obj = mrb_obj_new(M, mrb_class_get(M, "RPG2k"), 0, nullptr);
  mrb_funcall(M, obj, "start", 0);
  CHECK(!M->exc);

  while (true) {
    if (FLAGS_timeout_ms > 0 && (lv_tick_get() - start) > FLAGS_timeout_ms) {
      break;
    }

    const uint32_t frame_start = lv_tick_get();

    lv_canvas_fill_bg(canvas.get(), lv_color_hex3(0x000), LV_OPA_COVER);

    /*
    lv_layer_t layer;
    lv_canvas_init_layer(canvas.get(), &layer);
    lv_area_t coords = {10 + frame % 100, 10 + frame % 100, 50 + frame % 100,
                        50 + frame % 100};
    lv_draw_rect(&layer, &rect, &coords);
    lv_canvas_finish_layer(canvas.get(), &layer);
    */

    lv_timer_handler();
    lv_task_handler();

    const int32_t sleep = 1000 / 60 - lv_tick_elaps(frame_start);
    if (sleep > 0) {
      lv_delay_ms(sleep);
    }
    frame++;
  }

  gflags::ShutDownCommandLineFlags();

  return EXIT_SUCCESS;
}
