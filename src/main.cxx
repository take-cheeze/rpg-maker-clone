
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
#include "log_console.hxx"
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
DEFINE_string(
    mv_screenshot,
    "",
    "For RPG Maker MV: write a PNG of the rendered frame to this path "
    "after boot, then keep running (used to capture output in CI)");
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
DEFINE_bool(
    term_console,
    true,
    "While a terminal backend (--sixel/--iterm) is active, draw a log "
    "console above the game image that mirrors ng-log messages on-screen "
    "(so they are not scribbled over the picture via stderr); the last "
    "--term_console_lines messages are tailed, newest at the bottom");
DEFINE_int32(term_console_lines,
             5,
             "Number of ng-log message rows the --term_console panel reserves");
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

#ifndef __EMSCRIPTEN__
// mruby's heap is routed through lvgl's memory pool so both are accounted under
// one allocator. mruby 4.0 removed per-state allocators (mrb_open_allocf); a
// program now customizes allocation by overriding the global
// mrb_basic_alloc_func (see below), whose (ptr, size) contract this matches:
// size 0 frees, a non-null ptr reallocs, otherwise it allocates.
void* lvallocf(void* p, size_t s) {
  if (s == 0) {
    lv_free(p);
    return nullptr;
  } else if (p) {
    return lv_realloc(p, s);
  } else {
    return lv_malloc(s);
  }
}

// When --profile is on, allocations are routed through the profiler so it can
// count activity (it forwards to lvallocf); otherwise they go straight to
// lvallocf, so the unprofiled build pays no extra indirection. Set from main()
// before mruby is opened.
bool g_alloc_through_profiler = false;
#endif

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

// The interpreter, display and constructor args must outlive main() so a game
// can be constructed later, once the page's loader has unzipped a project into
// /game at runtime (see rpg_start_game). EXIT_RUNTIME=0 keeps the module alive
// after main() returns, so these globals stay valid until the tab is closed.
std::shared_ptr<mrb_state> em_mrb;
std::shared_ptr<lv_display_t> em_display;
mrb_value em_args;
#endif

}  // namespace

#ifndef __EMSCRIPTEN__
// mruby 4.0 has no per-state allocator hook; a program overrides the global
// mrb_basic_alloc_func to supply its own allocator. Defining it here means the
// linker never pulls mruby's default from libmruby.a. Route mruby's heap
// through lvgl's pool (via lvallocf), optionally counting through the profiler.
//
// The Emscripten build deliberately does NOT override it (see the mrb_open()
// note in main): lvgl's TLSF pool only aligns to 4 bytes on wasm32, which
// breaks mruby's word boxing, so there mruby keeps its default 16-byte-aligned
// malloc.
extern "C" void* mrb_basic_alloc_func(void* p, size_t size) {
  return g_alloc_through_profiler ? profiler_allocf(p, size)
                                  : lvallocf(p, size);
}
#endif

extern "C" void rgss_set_display(mrb_state* M, lv_display_t* d);

// Installs the SDL keyboard watch that feeds RGSS::Input (src/sdl_input.cxx).
// Only meaningful for the SDL window backend.
extern "C" void rgss_sdl_input_init(void);

// Opens the audio device and installs the SDL_mixer backend for RGSS::Audio
// (src/sdl_audio.cxx). A no-op if audio cannot be initialised. rgss_audio_
// shutdown tears it down on the native exit path.
extern "C" void rgss_audio_init(void);
extern "C" void rgss_audio_shutdown(void);

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

#ifdef __EMSCRIPTEN__
// Construct the game object from whatever now lives under /game and hand a
// per-frame callback to the browser. Exported so the shell page's loader can
// call it (via Module.ccall) after unzipping an RPG2k/XP project into the
// virtual filesystem. Returns 0 on success, 1 when no recognisable game is
// present or its construction raised a Ruby exception. Safe to call only once:
// once a game is running the browser owns the frame loop.
extern "C" EMSCRIPTEN_KEEPALIVE int rpg_start_game(void) {
  mrb_state* M = em_mrb.get();
  if (M == nullptr)
    return 1;

  const fs::path game_dir_path = "/game";
  mrb_value game_obj;
  if (fs::exists(game_dir_path / "RPG_RT.ldb")) {
    game_obj = mrb_obj_new(M, mrb_class_get(M, "RPG2k"), 1, &em_args);
  } else if (fs::exists(game_dir_path / "Game.ini")) {
    game_obj = mrb_obj_new(M, mrb_class_get(M, "RPGXP"), 1, &em_args);
  } else if (fs::exists(game_dir_path / "js" / "rpg_core.js") &&
             fs::exists(game_dir_path / "data" / "System.json")) {
    // RPG Maker MV: a JavaScript project (js/rpg_core.js + data/System.json).
    // Mirrors MV::REQUIRED_MARKERS; the embedded JS host runs the game's own
    // scripts (see mruby-mvjs). Lets the shell loader run MV projects too.
    game_obj = mrb_obj_new(M, mrb_class_get(M, "MV"), 1, &em_args);
  } else {
    std::fprintf(stderr,
                 "No RPG2k (RPG_RT.ldb), RPG XP (Game.ini) or RPG Maker MV "
                 "(js/rpg_core.js + data/System.json) project found under "
                 "/game\n");
    return 1;
  }
  if (M->exc) {
    mrb_print_backtrace(M);
    M->exc = nullptr;
    return 1;
  }

  // Keep the game reachable from the GC and capture handles by value so the
  // callback stays valid after this function returns. simulate_infinite_loop=0
  // so control returns cleanly to the JS caller instead of unwinding the stack.
  mrb_gc_register(M, game_obj);
  main_loop_ = [M, game_obj]() {
    mrb_funcall(M, game_obj, "main_loop", 0);
    if (M->exc) {
      mrb_print_backtrace(M);
      emscripten_cancel_main_loop();
    }
  };
  emscripten_set_main_loop(main_loop, 0, 0);
  return 0;
}
#endif

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

  // RPG Maker XP projects render at 640x480 (RPG2000/MV use 320x240). When the
  // window size was not overridden on the command line, size the canvas to the
  // XP resolution so an XP game's title and maps fill the screen. Detection
  // mirrors the game-class dispatch below: Game.ini plus a Data/System.rxdata.
  {
    const fs::path gd = FLAGS_game_dir;
    const bool xp_game = fs::exists(gd / "Game.ini") &&
                         fs::exists(gd / "Data" / "System.rxdata");
    gflags::CommandLineFlagInfo w_info, h_info;
    gflags::GetCommandLineFlagInfo("width", &w_info);
    gflags::GetCommandLineFlagInfo("height", &h_info);
    if (xp_game && w_info.is_default && h_info.is_default) {
      FLAGS_width = 640;
      FLAGS_height = 480;
    }
  }

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

  // The log console mirrors ng-log output on the alternate screen while a
  // terminal backend paints the game there; without it, ng-log's stderr writes
  // would scribble over the image.  Configure it always (harmless for the SDL
  // path, whose encoder never runs), but only install the sink and stop routing
  // messages to stderr when such a backend is actually active and the console
  // is enabled.
  const bool terminal_backend = FLAGS_sixel || FLAGS_iterm;
  terminal_set_console(FLAGS_term_console, FLAGS_term_console_lines);
  if (terminal_backend && FLAGS_term_console) {
    log_console_install();
    // Keep stderr clean so messages land only in the on-screen console; FATAL
    // still prints (it aborts and restores the terminal anyway).
    nglog::SetStderrLogging(nglog::NGLOG_FATAL);
  }

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
    // A 640x480 (XP) canvas is already large, so present it 1:1; the smaller
    // 320x240 (RPG2000/MV) canvas is doubled to a comfortable window size.
    lv_sdl_window_set_zoom(display.get(), FLAGS_width >= 640 ? 1.f : 2.f);
    // SDL is initialised by lv_sdl_window_create above; install the keyboard
    // watch now so key events reach RGSS::Input.
    rgss_sdl_input_init();
  }

  // Bring up audio for every backend (SDL_mixer initialises the SDL audio
  // subsystem itself, so this works under the terminal backends too).
  rgss_audio_init();

#ifdef __EMSCRIPTEN__
  // mruby uses word boxing, which stores the type tag in the low 3 bits of each
  // heap pointer and therefore requires 8-byte-aligned objects. lvgl's TLSF
  // only aligns to 4 bytes on 32-bit (wasm32), so objects at 4-mod-8 addresses
  // read back as "immediate" and every mrb_*_p type predicate fails, corrupting
  // core init. Use mruby's default allocator (emscripten malloc is 16-byte
  // aligned).
  std::shared_ptr<mrb_state> mrb(mrb_open(), mrb_close);
#else
  // mruby's allocator is the global mrb_basic_alloc_func override above, which
  // routes through lvgl's pool. With profiling on, register lvallocf as the
  // profiler's downstream and have the override count through it; this must
  // happen before mrb_open() takes the first allocation.
  if (profiling)
    profiler_set_downstream_allocf(lvallocf);
  g_alloc_through_profiler = profiling;
  std::shared_ptr<mrb_state> mrb(mrb_open(), mrb_close);
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
  mrb_const_set(M, mrb_obj_value(M->object_class),
                mrb_intern_lit(M, "MV_SCREENSHOT"),
                mrb_str_new_cstr(M, FLAGS_mv_screenshot.c_str()));
  CHECK_NO_EXC(M);

  const mrb_value args = mrb_ary_new_capa(M, argc - 1);
  for (int i = 1; i < argc; ++i)
    mrb_ary_push(M, args, mrb_str_new_cstr(M, argv[i]));

  const fs::path game_dir_path = FLAGS_game_dir;

#ifdef __EMSCRIPTEN__
  // The browser owns the event loop and a project may not be present yet:
  // main() sets up the interpreter and display, then returns to the browser.
  // The shell page's loader unzips an RPG2k/XP project into /game at runtime
  // and calls rpg_start_game() to construct the game and start the frame loop.
  // A project baked in at build time (WASM_GAME_DIR) is auto-started here so
  // that build still "just runs" with no interaction.
  //
  // These handles must outlive main(); EXIT_RUNTIME=0 keeps the module alive.
  em_mrb = mrb;
  em_display = display;
  em_args = args;
  mrb_gc_register(M, em_args);
  if (fs::exists(game_dir_path / "RPG_RT.ldb") ||
      fs::exists(game_dir_path / "Game.ini") ||
      (fs::exists(game_dir_path / "js" / "rpg_core.js") &&
       fs::exists(game_dir_path / "data" / "System.json"))) {
    rpg_start_game();
  } else {
    std::fprintf(stderr,
                 "No project baked in; waiting for the page to load one "
                 "into /game.\n");
  }
  return EXIT_SUCCESS;
#else
  mrb_value game_obj;
  if (fs::exists(game_dir_path / "RPG_RT.ldb")) {
    game_obj = mrb_obj_new(M, mrb_class_get(M, "RPG2k"), 1, &args);
  } else if (fs::exists(game_dir_path / "js" / "rpg_core.js") &&
             fs::exists(game_dir_path / "data" / "System.json")) {
    // RPG Maker MV: a JavaScript game (js/rpg_core.js) with a JSON database.
    // See docs/adr/0004-javascript-maker-mv-quickjs.md.
    game_obj = mrb_obj_new(M, mrb_class_get(M, "MV"), 1, &args);
  } else if (fs::exists(game_dir_path / "Game.ini")) {
    game_obj = mrb_obj_new(M, mrb_class_get(M, "RPGXP"), 1, &args);
  } else {
    CHECK(false) << "Unknown game directory: " << game_dir_path;
  }
  CHECK_NO_EXC(M);

  mrb_funcall(M, game_obj, "start", 0);
  if (M->exc) {
    mrb_print_backtrace(M);
  }
  CHECK(!M->exc);

  rgss_audio_shutdown();
  gflags::ShutDownCommandLineFlags();

  return EXIT_SUCCESS;
#endif
}
