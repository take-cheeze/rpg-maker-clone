
#include <cstdlib>
#include <filesystem>
#include <memory>
#include <regex>

#include <lvgl.h>
#include <mruby.h>
#include <mruby/array.h>
#include <mruby/variable.h>

#include <gflags/gflags.h>
#include <glog/logging.h>
#include <inicpp.hpp>

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

fs::path wine_prefix() {
  static const char* prefix_env = std::getenv("WINEPREFIX");
  static fs::path wine_prefix =
      prefix_env ? prefix_env : fs::path(std::getenv("HOME")) / ".wine";
  return wine_prefix;
}

inicpp::IniManager get_reg(const char* n) {
  return inicpp::IniManager(wine_prefix() / n);
}

fs::path reg2path(std::string r) {
  r = std::regex_replace(r, std::regex("\\\\\\\\"), "/");
  r = std::regex_replace(r, std::regex("^\"|\"$"), "");
  if (r.size() >= 2 && r[1] == ':') {
    const char drive_letter = std::tolower(r[0]);
    r = wine_prefix() / "dosdevices" / (drive_letter + std::string(":")) /
        r.substr(3);
  }
  return r;
}

fs::path rtp_path() {
  inicpp::IniManager ini = get_reg("user.reg");
  return reg2path(
      ini["Software\\\\ASCII\\\\RPG2000"]["\"RuntimePackagePath\""]);
}

fs::path xp_rtp_path() {
  inicpp::IniManager ini = get_reg("system.reg");
  return reg2path(ini["Software\\\\Enterbrain\\\\RGSS\\\\RTP"]["\"Standard\""]);
}

}  // namespace

extern "C" void rgss_set_display(mrb_state* M, lv_display_t* d);

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
  lv_sdl_window_set_zoom(display.get(), 2.f);

  std::shared_ptr<mrb_state> mrb(mrb_open_allocf(lvallocf, nullptr), mrb_close);
  mrb_state* M = mrb.get();
  CHECK(!M->exc);

  rgss_set_display(M, display.get());

  mrb_const_set(M, mrb_obj_value(M->object_class),
                mrb_intern_lit(M, "GAME_DIR"),
                mrb_str_new_cstr(M, FLAGS_game_dir.c_str()));
  mrb_const_set(M, mrb_obj_value(M->object_class), mrb_intern_lit(M, "RTP_DIR"),
                mrb_str_new_cstr(M, rtp_path().c_str()));
  mrb_const_set(M, mrb_obj_value(M->object_class),
                mrb_intern_lit(M, "TIMEOUT_MS"),
                mrb_fixnum_value(FLAGS_timeout_ms));
  CHECK(!M->exc);

  const mrb_value args = mrb_ary_new_capa(M, argc - 1);
  for (int i = 1; i < argc; ++i)
    mrb_ary_push(M, args, mrb_str_new_cstr(M, argv[i]));

  const fs::path game_dir_path = FLAGS_game_dir;

  if (fs::exists(game_dir_path / "RPG_RT.ldb")) {
    mrb_value obj = mrb_obj_new(M, mrb_class_get(M, "RPG2k"), 1, &args);
    mrb_funcall(M, obj, "start", 0);
  } else if (fs::exists(game_dir_path / "Game.ini")) {
    mrb_value obj = mrb_obj_new(M, mrb_class_get(M, "RPGXP"), 1, &args);
    mrb_funcall(M, obj, "start", 0);
  } else {
    CHECK(false) << "Unknown game directory: " << game_dir_path;
  }
  mrb_print_backtrace(M);
  CHECK(!M->exc);

  gflags::ShutDownCommandLineFlags();

  return EXIT_SUCCESS;
}
