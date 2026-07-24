
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <functional>
#include <memory>
#include <regex>

#include <lvgl.h>
#include <mruby.h>
#include <mruby/array.h>
#include <mruby/string.h>
#include <mruby/variable.h>

#include <gflags/gflags.h>
#include <ng-log/logging.h>
#include <inicpp.hpp>

#include "iterm.hxx"
#include "profiler.hxx"
#include "sixel.hxx"
#include "terminal.hxx"

#ifdef __EMSCRIPTEN__
#include <emscripten.h>
#endif

DEFINE_int64(timeout_ms, -1, "timeout to exit");
DEFINE_int64(width, 320, "width of the window");
DEFINE_int64(height, 240, "height of the window");
DEFINE_string(game_dir, "", "Game directory");
DEFINE_bool(sixel,
            false,
            "Render to the terminal using the sixel protocol instead of "
            "opening an SDL window");
DEFINE_int32(sixel_scale,
             1,
             "Integer upscale factor for the sixel terminal output");
DEFINE_bool(iterm,
            false,
            "Render to the terminal using iTerm2's inline-image protocol "
            "instead of opening an SDL window (works in iTerm2, WezTerm and "
            "VS Code's integrated terminal)");
DEFINE_int32(iterm_scale,
             1,
             "Integer upscale factor for the iTerm2 terminal output");
DEFINE_bool(
    term_stats,
    true,
    "While a terminal backend (--sixel/--iterm) is active, draw the "
    "emit rate (frame size, MB/s, fps) on-screen just under the control "
    "legend, refreshed about once a second");
DEFINE_bool(profile,
            false,
            "Enable the CPU/memory profiler: measure per-frame work time and "
            "named sub-sections (scene/input/graphics) plus memory use "
            "(process RSS, the LVGL heap pool and mruby allocation activity), "
            "and print a summary line to stderr about once a second");
DEFINE_int32(profile_interval_ms,
             1000,
             "How often (ms) the --profile summary line is printed");
DEFINE_string(profile_trace,
              "",
              "Stream a Chrome trace (chrome://tracing / Perfetto JSON) of "
              "every frame and section to this file. Implies --profile");

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

// Read the [RPG_RT] FullPackageFlag from RPG_RT.ini in the game directory. When
// set to 1 the game bundles every asset it needs ("full package") and must not
// fall back to the RTP, so the runtime disables RTP lookups entirely.
bool full_package_flag(const fs::path& game_dir) {
  const fs::path ini_path = game_dir / "RPG_RT.ini";
  if (!fs::exists(ini_path))
    return false;
  return inicpp::IniManager(ini_path.string())["RPG_RT"].toInt(
             "FullPackageFlag") == 1;
}

#ifdef __EMSCRIPTEN__
// Trampoline for emscripten_set_main_loop, which takes a plain function
// pointer.
std::function<void()> main_loop_;
void main_loop() {
  main_loop_();
}
#endif

}  // namespace

extern "C" void rgss_set_display(mrb_state* M, lv_display_t* d);

// Installs the SDL keyboard watch that feeds RGSS::Input (src/sdl_input.cxx).
// Only meaningful for the SDL window backend.
extern "C" void rgss_sdl_input_init(void);

// Report an mruby exception (class, message, and Ruby backtrace) and bail out
// of main(). Preferred over ng-log's CHECK: it prints the actual mruby error
// detail, and under Emscripten ng-log's fatal path traps anyway (it formats
// through std::ios callbacks that don't survive the wasm function-pointer
// table), so we use mruby's own stdio-based printer, which also reaches the
// browser console.
#define CHECK_NO_EXC(M)                                                        \
  do {                                                                         \
    if ((M)->exc) {                                                            \
      mrb_value exc__ = mrb_obj_value((M)->exc);                               \
      (M)->exc = nullptr;                                                      \
      mrb_value msg__ = mrb_funcall(M, exc__, "message", 0);                   \
      std::fprintf(stderr, "mruby error: %s: %s\n",                            \
                   mrb_obj_classname(M, exc__),                                \
                   mrb_string_value_cstr(M, &msg__));                          \
      /* mrb_print_backtrace reads mrb->exc, so restore it around the call. */ \
      (M)->exc = mrb_obj_ptr(exc__);                                           \
      mrb_print_backtrace(M);                                                  \
      (M)->exc = nullptr;                                                      \
      return EXIT_FAILURE;                                                     \
    }                                                                          \
  } while (0)

int main(int argc, char** argv) {
  gflags::ParseCommandLineFlags(&argc, &argv, true);
  if (FLAGS_game_dir.empty()) {
#ifdef __EMSCRIPTEN__
    // A game directory is baked into the virtual filesystem at /game (see the
    // WASM_GAME_DIR option in CMakeLists.txt).
    FLAGS_game_dir = "/game";
#else
    FLAGS_game_dir = fs::current_path();
#endif
  }
  nglog::InitializeLogging(argv[0]);

  // Configure profiling before mruby is opened so the allocator hook, if it is
  // installed below, sees the right enabled state from its first call. A
  // requested trace implies profiling.
  const bool profiling = FLAGS_profile || !FLAGS_profile_trace.empty();
  profiler_configure(profiling, FLAGS_profile_interval_ms);
  if (!FLAGS_profile_trace.empty())
    profiler_trace_start(FLAGS_profile_trace.c_str());

  lv_init();

  CHECK(!(FLAGS_sixel && FLAGS_iterm))
      << "--sixel and --iterm are mutually exclusive; pick one terminal "
         "backend";

  terminal_set_stats(FLAGS_term_stats);

  std::shared_ptr<lv_display_t> display;
  if (FLAGS_sixel) {
    display = std::shared_ptr<lv_display_t>(
        sixel_display_create(FLAGS_width, FLAGS_height, FLAGS_sixel_scale),
        [](lv_display_t*) {});
    CHECK(display);
  } else if (FLAGS_iterm) {
    display = std::shared_ptr<lv_display_t>(
        iterm_display_create(FLAGS_width, FLAGS_height, FLAGS_iterm_scale),
        [](lv_display_t*) {});
    CHECK(display);
  } else {
    display = std::shared_ptr<lv_display_t>(
        lv_sdl_window_create(FLAGS_width, FLAGS_height),
        [](lv_display_t*) { lv_sdl_quit(); });
    CHECK(display);
    lv_sdl_window_set_resizeable(display.get(), false);
    lv_sdl_window_set_zoom(display.get(), 2.f);
    // SDL is initialised by lv_sdl_window_create above; install the keyboard
    // watch now so key events reach RGSS::Input.
    rgss_sdl_input_init();
  }

#ifdef __EMSCRIPTEN__
  // mruby uses word boxing, which stores the type tag in the low 3 bits of each
  // heap pointer and therefore requires 8-byte-aligned objects. lvgl's TLSF
  // only aligns to 4 bytes on 32-bit (wasm32), so objects at 4-mod-8 addresses
  // read back as "immediate" and every mrb_*_p type predicate fails, corrupting
  // core init. Use mruby's default allocator (emscripten malloc is 16-byte
  // aligned).
  std::shared_ptr<mrb_state> mrb(mrb_open(), mrb_close);
#else
  // With profiling on, route mruby's allocator through the profiler so it can
  // count allocation activity; it forwards every call to lvallocf. Off by
  // default, so the unprofiled build allocates through lvallocf directly.
  profiler_allocf_t allocf = lvallocf;
  if (profiling) {
    profiler_set_downstream_allocf(lvallocf);
    allocf = profiler_allocf;
  }
  std::shared_ptr<mrb_state> mrb(mrb_open_allocf(allocf, nullptr), mrb_close);
#endif
  mrb_state* M = mrb.get();
  CHECK_NO_EXC(M);

  rgss_set_display(M, display.get());

  mrb_const_set(M, mrb_obj_value(M->object_class),
                mrb_intern_lit(M, "GAME_DIR"),
                mrb_str_new_cstr(M, FLAGS_game_dir.c_str()));
#ifdef __EMSCRIPTEN__
  // The wine registry (used to locate the RTP) does not exist in the browser
  // filesystem, so leave RTP_DIR empty; games are expected to be self-contained
  // in the preloaded game directory.
  mrb_const_set(M, mrb_obj_value(M->object_class), mrb_intern_lit(M, "RTP_DIR"),
                mrb_str_new_cstr(M, ""));
#else
  // RPG_RT.ini's FullPackageFlag=1 marks a self-contained game; honour it by
  // clearing RTP_DIR so bitmap lookups never reach into the installed RTP.
  const std::string rtp_dir =
      full_package_flag(FLAGS_game_dir) ? std::string() : rtp_path().string();
  mrb_const_set(M, mrb_obj_value(M->object_class), mrb_intern_lit(M, "RTP_DIR"),
                mrb_str_new_cstr(M, rtp_dir.c_str()));
#endif
  mrb_const_set(M, mrb_obj_value(M->object_class),
                mrb_intern_lit(M, "TIMEOUT_MS"),
                mrb_fixnum_value(FLAGS_timeout_ms));
  CHECK_NO_EXC(M);

  const mrb_value args = mrb_ary_new_capa(M, argc - 1);
  for (int i = 1; i < argc; ++i)
    mrb_ary_push(M, args, mrb_str_new_cstr(M, argv[i]));

  const fs::path game_dir_path = FLAGS_game_dir;

  mrb_value game_obj;
  if (fs::exists(game_dir_path / "RPG_RT.ldb")) {
    game_obj = mrb_obj_new(M, mrb_class_get(M, "RPG2k"), 1, &args);
  } else if (fs::exists(game_dir_path / "Game.ini")) {
    game_obj = mrb_obj_new(M, mrb_class_get(M, "RPGXP"), 1, &args);
  } else {
    CHECK(false) << "Unknown game directory: " << game_dir_path;
  }
  CHECK_NO_EXC(M);

#ifdef __EMSCRIPTEN__
  // The browser owns the event loop, so we cannot block in a Ruby `loop`.
  // Instead we register a per-frame callback that runs a single iteration.
  //
  // emscripten_set_main_loop(..., simulate_infinite_loop=1) unwinds the C stack
  // without running destructors, so `mrb`, `display` and `game_obj`
  // intentionally outlive main(). Keep `game_obj` reachable from the GC and
  // capture handles by value so the callback stays valid after main() returns
  // to the browser.
  mrb_gc_register(M, game_obj);
  main_loop_ = [M, game_obj]() {
    mrb_funcall(M, game_obj, "main_loop", 0);
    if (M->exc) {
      mrb_print_backtrace(M);
      emscripten_cancel_main_loop();
    }
  };
  emscripten_set_main_loop(main_loop, 0, 1);
  return EXIT_SUCCESS;  // not reached; the call above unwinds the stack
#else
  mrb_funcall(M, game_obj, "start", 0);
  if (M->exc) {
    mrb_print_backtrace(M);
  }
  CHECK(!M->exc);

  gflags::ShutDownCommandLineFlags();

  return EXIT_SUCCESS;
#endif
}
