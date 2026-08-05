
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <functional>
#include <memory>
#include <regex>
#include <string>

#include <lvgl.h>
#include <mruby.h>
#include <mruby/array.h>
#include <mruby/string.h>
#include <mruby/variable.h>

#include <gflags/gflags.h>
#include <ng-log/logging.h>
#include <inicpp.hpp>

#include "default_font.hxx"
#include "error_dump.hxx"
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
DEFINE_bool(
    rpg2k_new_game,
    false,
    "For RPG Maker 2000/2003: once the title screen appears, auto-select New "
    "Game so the game advances into its first map without input, and log the "
    "scene it reaches as [RPG2k-MAP]. Used to smoke-test the LCF path in CI "
    "(the title screen alone never exercises the map renderer)");
DEFINE_bool(
    rpg2k_continue,
    false,
    "For RPG Maker 2000/2003: once the title screen appears, auto-select "
    "Continue so the game resumes from the save in the game directory without "
    "input, and log the map it reaches as [RPG2k-MAP]. Lets both this engine "
    "and a genuine RPG_RT.exe be brought to the same in-game map from the same "
    "Save<N>.lsd (see scripts/compare-nepheshel-save-wine.bash) instead of "
    "being driven there by counting key presses");
DEFINE_bool(
    rpgxp_new_game,
    false,
    "For RPG Maker XP: once the title screen appears, auto-select New Game so "
    "the game advances into its start map without input, and log the map it "
    "reaches as [RPGXP-MAP]. Used to smoke-test the RGSS path headlessly (in "
    "CI, in the browser build and beside the genuine RGSS runtime under wine; "
    "see scripts/rpgxp_boot_check.bash and scripts/compare-rpgxp-wine.bash). "
    "It is the *built-in* title screen this drives, so the flag also runs the "
    "built-in reimplemented flow in place of the default RGSS script host "
    "(equivalent to --norgss_script_host)");
DEFINE_bool(
    rgss_script_host,
    true,
    "For the RGSS makers (XP / VX / VX Ace): run the project's own bundled "
    "scripts (Data/Scripts.rxdata, Scripts.rvdata[2]) the way RGSS104E.dll "
    "does. On by default; --norgss_script_host boots the built-in "
    "reimplemented "
    "title/map flow instead, which is also what a project shipping no scripts "
    "and a script host that fails to boot fall back to. The RGSS_SCRIPT_HOST "
    "environment variable seeds this flag (set it to 0/false/off/no to opt "
    "out); an explicit --rgss_script_host on the command line wins over it. "
    "See docs/adr/0029-rgss-script-host-by-default.md");
DEFINE_bool(
    mv_new_game,
    false,
    "For RPG Maker MV: once the title screen appears, auto-select New Game so "
    "the game advances to its first map without input (used to capture "
    "in-game output in CI)");
DEFINE_int32(
    mv_battle_test,
    0,
    "For RPG Maker MV: once on the map, start a test battle against this troop "
    "id (implies --mv_new_game to reach the map). 0 disables. Used to capture "
    "the battle scene in CI");
DEFINE_bool(
    mv_move_test,
    false,
    "For RPG Maker MV: once on the map, hold a direction for a spell (implies "
    "--mv_new_game to reach the map) and log the player's start/end tile, so a "
    "headless run confirms input actually moves the player. Used in CI");
DEFINE_bool(
    mv_message_test,
    false,
    "For RPG Maker MV: once on the map, show a text message (implies "
    "--mv_new_game to reach the map) and log whether the message window "
    "opened, so a headless run confirms the message/window path renders. "
    "Used in CI");
DEFINE_bool(
    mv_menu_test,
    false,
    "For RPG Maker MV: once on the map, press the cancel/menu button (implies "
    "--mv_new_game to reach the map) and log whether Scene_Menu opened, so a "
    "headless run confirms the menu path works. Used in CI");
DEFINE_bool(
    mv_save_test,
    false,
    "For RPG Maker MV: once on the map, save to a slot and load it back "
    "(implies --mv_new_game to reach the map) and log whether the save/load "
    "round-trip succeeded, so a headless run confirms the save path works. "
    "Used in CI");
DEFINE_bool(
    mv_audio_test,
    false,
    "For RPG Maker MV: once on the map, play a sound effect through the audio "
    "bridge (implies --mv_new_game to reach the map) and log whether the op "
    "reached RGSS::Audio and the asset resolves, so a headless run confirms "
    "the audio path works. Used in CI");
DEFINE_bool(
    mz_new_game,
    false,
    "For RPG Maker MZ: once the title screen appears, auto-select New Game so "
    "the game advances to its start map without input (used to capture "
    "in-game output in CI)");
DEFINE_bool(
    mz_move_test,
    false,
    "For RPG Maker MZ: once on the map, hold a direction for a spell (implies "
    "--mz_new_game to reach the map) and log the player's start/end tile, so a "
    "headless run confirms input actually moves the player. Used in CI");
DEFINE_bool(
    mz_audio_test,
    false,
    "For RPG Maker MZ: once on the map, play a sound effect through the audio "
    "bridge (implies --mz_new_game to reach the map) and log whether the op "
    "reached RGSS::Audio and the asset resolves, so a headless run confirms "
    "the audio path works. Used in CI");
DEFINE_string(
    mz_screenshot,
    "",
    "For RPG Maker MZ: write a PNG of the presented WebGL frame to this path "
    "after boot, then keep running (used to capture output in CI)");
DEFINE_bool(
    rgss_effect_probe,
    false,
    "Drive the RGSS screen effects on a real display and measure the rendered "
    "frame (RGSS.effect_probe): a grey screen, then a viewport colour overlay, "
    "then a viewport tone, each compared against the last. Exits 0 only if the "
    "pixels actually moved. Needs no game; run under xvfb in CI as the "
    "render_probe ctest — the one check that can catch \"the effect code runs "
    "and the screen does not change\"");
DEFINE_bool(
    rgss_audio_probe,
    false,
    "Play a sound through the real mixer, first from a loose file and then out "
    "of an encrypted archive, and check both advance Audio.bgm_pos "
    "(RGSS.audio_probe). Exits 0 only if the archived one played too. Needs no "
    "game; run with SDL_AUDIODRIVER=dummy in CI as the audio_probe ctest, "
    "which decodes and mixes with no sound card");
DEFINE_bool(
    error_dump_probe,
    false,
    "Raise a real Ruby exception through the crash-report path and read the "
    "report back (error_dump_run_probe): it must carry the exception, its "
    "backtrace and the runtime log captured before the raise, and the "
    "--error_dump file must hold the same text that was printed. Exits 0 only "
    "then. Needs no game; run as the error_dump ctest — a report that silently "
    "lost half its content is worse than no report at all");
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

// RPG Maker XP's native screen size (RPG2000/MV render at 320x240). Mirrors
// RPGXP::WIDTH / RPGXP::HEIGHT in mruby-rpgxp/mrblib/lib.rb; the display is
// sized to it whenever an XP project is the one being booted.
constexpr int RPGXP_WIDTH = 640;
constexpr int RPGXP_HEIGHT = 480;

// RPG Maker VX / VX Ace's native screen size (mruby-rpgvx).
constexpr int RPGVX_WIDTH = 544;
constexpr int RPGVX_HEIGHT = 416;

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

// The RTP a project asks for, from its own Game.ini: RPG Maker XP writes
// `RTP1=Standard` (plus optional RTP2/RTP3 slots), VX and VX Ace a single
// `RTP=RPGVX` / `RTP=RPGVXAce`. That name is the registry *value* the runtime
// looks up under its edition's key, so reading it here resolves a project that
// ships with a differently named RTP instead of assuming the stock one.
std::string ini_rtp_name(const fs::path& game_dir) {
  const fs::path ini_path = game_dir / "Game.ini";
  if (!fs::exists(ini_path))
    return std::string();
  inicpp::IniManager ini(ini_path.string());
  std::string name = ini["Game"].toString("RTP1");
  if (name.empty())
    name = ini["Game"].toString("RTP");
  return name;
}

// Each RGSS generation registers its RTPs under its own key, keyed by RTP name:
// RGSS (XP) -> "Standard", RGSS2 (VX) -> "RPGVX", RGSS3 (VX Ace) -> "RPGVXAce".
fs::path rgss_rtp_path(const std::string& rgss_key,
                       const std::string& name,
                       const char* fallback) {
  inicpp::IniManager ini = get_reg("system.reg");
  const std::string section =
      "Software\\\\Enterbrain\\\\" + rgss_key + "\\\\RTP";
  const std::string value =
      "\"" + (name.empty() ? std::string(fallback) : name) + "\"";
  return reg2path(ini[section][value]);
}

fs::path xp_rtp_path(const fs::path& game_dir) {
  return rgss_rtp_path("RGSS", ini_rtp_name(game_dir), "Standard");
}

// RPG Maker VX / VX Ace projects look like XP ones from the outside — a
// Game.ini beside a Data/ folder — so they have to be recognised before the XP
// check below, which keys on Game.ini alone. Mirrors RPGVX::EDITIONS
// (mruby-rpgvx/mrblib/lib.rb): an unpacked project is identified by
// Data/System.rvdata(2), a packed release by its encrypted archive
// (Game.rgss2a / Game.rgss3a), since such a release ships no loose Data/ at
// all. The Ruby side re-detects which of the two editions it is.
bool is_rpgvx_game(const fs::path& gd) {
  return fs::exists(gd / "Data" / "System.rvdata2") ||
         fs::exists(gd / "Data" / "System.rvdata") ||
         fs::exists(gd / "Game.rgss3a") || fs::exists(gd / "Game.rgss2a");
}

// VX Ace (RGSS3) rather than VX (RGSS2); only meaningful for a VX-family
// project. The two editions install their RTPs under different keys.
bool is_rpgvxace_game(const fs::path& gd) {
  return fs::exists(gd / "Data" / "System.rvdata2") ||
         fs::exists(gd / "Game.rgss3a");
}

fs::path vx_rtp_path(const fs::path& gd) {
  const bool ace = is_rpgvxace_game(gd);
  return rgss_rtp_path(ace ? "RGSS3" : "RGSS2", ini_rtp_name(gd),
                       ace ? "RPGVXAce" : "RPGVX");
}

// An RPG Maker XP project: Game.ini plus either a loose Data/System.rxdata or
// XP's own encrypted archive (a packed release ships no loose Data/ folder),
// and not a VX / VX Ace project, whose archives are its own. Mirrors the
// game-class dispatch in main(), and decides both the screen size and which RTP
// registry key the assets are looked up under.
bool is_xp_game(const fs::path& game_dir) {
  if (is_rpgvx_game(game_dir))
    return false;
  const bool xp_data = fs::exists(game_dir / "Data" / "System.rxdata") ||
                       fs::exists(game_dir / "Game.rgssad");
  return fs::exists(game_dir / "Game.ini") && xp_data;
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

// Tell the text renderer where this build keeps the bundled default UI font —
// the font used when a project ships none of its own, which is most of what the
// XP/VX/MV/MZ runtimes are handed (see assets/fonts/README.md). The gem that
// rasterises text cannot know these paths: it is also built for the
// terminal-only and Emscripten variants, so it stays free of build-system
// wiring and takes them from here.
//
// Probed at run time, never at configure time, matching the MIDI patch set: the
// download is independent of the configure, so an EXISTS check would freeze
// whichever order the two happened to run in.
void init_default_font() {
  // Installed layout first, then the source tree, the same order sdl_audio.cxx
  // probes for the patch set.
  rgss::add_default_font_dir(RGSS_DEFAULT_FONT_INSTALL_DIR);
  rgss::add_default_font_dir(RGSS_DEFAULT_FONT_SOURCE_DIR);

  const std::string& path = rgss::default_font_path();
  if (path.empty()) {
    LOG(INFO)
        << "Text: no default font installed; a project that ships none of "
           "its own draws with the built-in shinonome bitmap font at its "
           "fixed 12px. Run scripts/download-default-font.bash to add one.";
  } else {
    LOG(INFO) << "Text: default font from '" << path << "'";
  }
}

extern "C" void rgss_set_display(mrb_state* M, lv_display_t* d);

// Installs the SDL keyboard watch that feeds RGSS::Input (src/sdl_input.cxx).
// Only meaningful for the SDL window backend.
extern "C" void rgss_sdl_input_init(void);

// Opens the audio device and installs the SDL_mixer backend for RGSS::Audio
// (src/sdl_audio.cxx). A no-op if audio cannot be initialised. rgss_audio_
// shutdown tears it down on the native exit path.
extern "C" void rgss_audio_init(void);
extern "C" void rgss_audio_shutdown(void);

// Report an mruby exception and bail out of main(). Preferred over ng-log's
// CHECK: it reports the actual mruby error detail, and under Emscripten
// ng-log's fatal path traps anyway (it formats through std::ios callbacks that
// don't survive the wasm function-pointer table), while error_dump_report goes
// through plain stdio, which also reaches the browser console.
//
// The report is the copy-pasteable block described in include/error_dump.hxx --
// the exception, its backtrace, this build and the runtime log leading up to it
// -- so a player can hand a bug report over without a terminal. `where` is
// stringised from the failing line, since these sites are otherwise
// indistinguishable in a report.
#define CHECK_NO_EXC_STR2(x) #x
#define CHECK_NO_EXC_STR(x) CHECK_NO_EXC_STR2(x)
#define CHECK_NO_EXC(M)                                                 \
  do {                                                                  \
    if ((M)->exc) {                                                     \
      error_dump_report(M, "src/main.cxx:" CHECK_NO_EXC_STR(__LINE__)); \
      return EXIT_FAILURE;                                              \
    }                                                                   \
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
  // Which maker was detected is recorded for the crash report before the
  // runtime is built, so a report from a failed construction still says what
  // the engine thought it was loading.
  if (fs::exists(game_dir_path / "RPG_RT.ldb")) {
    error_dump_set_context("project", "RPG Maker 2000/2003 (RPG_RT.ldb)");
    game_obj = mrb_obj_new(M, mrb_class_get(M, "RPG2k"), 1, &em_args);
  } else if (is_rpgvx_game(game_dir_path)) {
    // RPG Maker VX / VX Ace: checked before the XP branch below, which only
    // looks for Game.ini — a VX project has one too. See mruby-rpgvx.
    error_dump_set_context("project", "RPG Maker VX / VX Ace");
    game_obj = mrb_obj_new(M, mrb_class_get(M, "RPGVX"), 1, &em_args);
  } else if (fs::exists(game_dir_path / "Game.ini")) {
    // RPG Maker XP renders at 640x480. Native main() sizes the display from
    // --game_dir before creating it, but in the browser no project exists yet
    // at that point (the page's loader mounts one here, later), so the display
    // was created at the 320x240 default and doubled. Resize it now, before the
    // runtime builds any screen-sized object: with a 320x240 canvas the XP
    // scenes draw off the edge -- the title's command window lands past the
    // bottom and its centred text past the right (found by the browser check
    // that ADR 0025 has since dropped; see docs/adr/0025).
    if (em_display) {
      lv_display_set_resolution(em_display.get(), RPGXP_WIDTH, RPGXP_HEIGHT);
      lv_sdl_window_set_zoom(em_display.get(), 1.f);
      std::fprintf(stderr, "[RPGXP] display sized to %dx%d\n", RPGXP_WIDTH,
                   RPGXP_HEIGHT);
    }
    error_dump_set_context("project", "RPG Maker XP (Game.ini)");
    game_obj = mrb_obj_new(M, mrb_class_get(M, "RPGXP"), 1, &em_args);
  } else if (fs::exists(game_dir_path / "js" / "rmmz_core.js") &&
             fs::exists(game_dir_path / "data" / "System.json")) {
    // RPG Maker MZ: a JavaScript project (js/rmmz_core.js + data/System.json).
    // Mirrors MZ::REQUIRED_MARKERS. MZ shares MV's embedded JS host but ships
    // PIXI v5 (WebGL-only); the WebGL backend it needs is not built yet, so
    // this reports the pending state instead of the "no project found" error
    // below (see mruby-mvjs/mrblib/mz.rb, docs/adr/0004 M6).
    error_dump_set_context("project", "RPG Maker MZ (js/rmmz_core.js)");
    game_obj = mrb_obj_new(M, mrb_class_get(M, "MZ"), 1, &em_args);
  } else if (fs::exists(game_dir_path / "js" / "rpg_core.js") &&
             fs::exists(game_dir_path / "data" / "System.json")) {
    // RPG Maker MV: a JavaScript project (js/rpg_core.js + data/System.json).
    // Mirrors MV::REQUIRED_MARKERS; the embedded JS host runs the game's own
    // scripts (see mruby-mvjs). Lets the shell loader run MV projects too.
    error_dump_set_context("project", "RPG Maker MV (js/rpg_core.js)");
    game_obj = mrb_obj_new(M, mrb_class_get(M, "MV"), 1, &em_args);
  } else {
    std::fprintf(stderr,
                 "No RPG2k (RPG_RT.ldb), RPG XP (Game.ini), RPG Maker VX / VX "
                 "Ace (Data/System.rvdata[2]), RPG Maker MV "
                 "(js/rpg_core.js + data/System.json) or RPG Maker MZ "
                 "(js/rmmz_core.js + data/System.json) project found under "
                 "/game\n");
    return 1;
  }
  if (M->exc) {
    error_dump_report(M, "loading the project");
    return 1;
  }

  // Keep the game reachable from the GC and capture handles by value so the
  // callback stays valid after this function returns. simulate_infinite_loop=0
  // so control returns cleanly to the JS caller instead of unwinding the stack.
  mrb_gc_register(M, game_obj);
  main_loop_ = [M, game_obj]() {
    mrb_funcall(M, game_obj, "main_loop", 0);
    if (M->exc) {
      error_dump_report(M, "the frame loop");
      emscripten_cancel_main_loop();
    }
  };
  emscripten_set_main_loop(main_loop, 0, 0);
  return 0;
}
#endif

// The value RGSS_SCRIPT_HOST asks for. The script host is on by default, so the
// variable is an opt-out and only these spellings mean "off" -- the same list
// RPGXP::ScriptHost::DISABLED_VALUES holds on the Ruby side (empty, unset or
// anything else leaves the host on).
static bool script_host_env_enabled(const std::string& value) {
  return !(value == "0" || value == "false" || value == "off" || value == "no");
}

int main(int argc, char** argv) {
  // Seed the script-host flag from the environment *before* parsing, so an
  // explicit --rgss_script_host on the command line still wins. The variable is
  // the documented opt-out and this mruby build has no ENV for the Ruby side to
  // read, so the native runtime resolves it and hands Ruby the answer as the
  // RGSS_SCRIPT_HOST constant below.
  if (const char* host_env = std::getenv("RGSS_SCRIPT_HOST"))
    if (*host_env != '\0')
      FLAGS_rgss_script_host = script_host_env_enabled(host_env);

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

  // RPG Maker XP projects render at 640x480 and VX / VX Ace ones at 544x416
  // (RPG2000/MV use 320x240). When the window size was not overridden on the
  // command line, size the canvas to the detected maker's resolution so its
  // title and maps fill the screen. Detection mirrors the game-class dispatch
  // below: VX first (its archives, .rgss2a / .rgss3a, are *not* XP markers),
  // then Game.ini plus either a loose Data/System.rxdata or an XP archive,
  // since a packed release ships no loose Data/ folder.
  {
    const bool xp_game = is_xp_game(FLAGS_game_dir);
    const bool vx_game = is_rpgvx_game(FLAGS_game_dir);
    gflags::CommandLineFlagInfo w_info, h_info;
    gflags::GetCommandLineFlagInfo("width", &w_info);
    gflags::GetCommandLineFlagInfo("height", &h_info);
    if (w_info.is_default && h_info.is_default) {
      if (xp_game) {
        FLAGS_width = RPGXP_WIDTH;
        FLAGS_height = RPGXP_HEIGHT;
      } else if (vx_game) {
        FLAGS_width = RPGVX_WIDTH;
        FLAGS_height = RPGVX_HEIGHT;
      }
    }
  }

  // Everything a crash report should say about this run but cannot work out
  // for itself. Recorded before anything can fail, so even a failure during
  // start-up carries it (see include/error_dump.hxx).
  error_dump_set_context("game dir", FLAGS_game_dir);
  error_dump_set_context("screen", std::to_string(FLAGS_width) + "x" +
                                       std::to_string(FLAGS_height));
  error_dump_set_context("display backend", FLAGS_sixel   ? "sixel terminal"
                                            : FLAGS_iterm ? "iTerm2 terminal"
                                                          : "SDL window");

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

  // Before any game runs, so the first window drawn already has its font.
  init_default_font();

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

  // Start tailing the runtime log now, so anything the game reports on its way
  // down is in the crash report — including whatever the boot itself logs.
  error_dump_install(M);

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
  //
  // Each maker registers its RTP under its own key and lays it out differently,
  // so pick by project type: RPG Maker XP resolves
  // Software\Enterbrain\RGSS\RTP (whose tree is rooted at Graphics/ and Audio/,
  // matching the "Graphics/Titles/..." paths XP data stores), VX and VX Ace the
  // same shape under RGSS2 / RGSS3, and RPG2000
  // Software\ASCII\RPG2000\RuntimePackagePath. Only the RPG2000 key was wired
  // up before, so an XP project could never find its RTP art and every asset
  // fell back to a placeholder (found while bringing up
  // scripts/compare-rpgxp-wine.bash, which needs both runtimes to draw the same
  // pictures to be worth anything) -- and a VX project still resolved the
  // RPG2000 path, which can never hold its assets.
  const fs::path game_dir = FLAGS_game_dir;
  const std::string rtp_dir =
      full_package_flag(game_dir) ? std::string()
      : is_xp_game(game_dir)      ? xp_rtp_path(game_dir).string()
      : is_rpgvx_game(game_dir)   ? vx_rtp_path(game_dir).string()
                                  : rtp_path().string();
  mrb_const_set(M, mrb_obj_value(M->object_class), mrb_intern_lit(M, "RTP_DIR"),
                mrb_str_new_cstr(M, rtp_dir.c_str()));
#endif
  mrb_const_set(M, mrb_obj_value(M->object_class),
                mrb_intern_lit(M, "TIMEOUT_MS"),
                mrb_fixnum_value(FLAGS_timeout_ms));
  mrb_const_set(M, mrb_obj_value(M->object_class),
                mrb_intern_lit(M, "RPG2K_NEW_GAME"),
                mrb_bool_value(FLAGS_rpg2k_new_game));
  mrb_const_set(M, mrb_obj_value(M->object_class),
                mrb_intern_lit(M, "RPG2K_CONTINUE"),
                mrb_bool_value(FLAGS_rpg2k_continue));
  mrb_const_set(M, mrb_obj_value(M->object_class),
                mrb_intern_lit(M, "RPGXP_NEW_GAME"),
                mrb_bool_value(FLAGS_rpgxp_new_game));
  // Whether the RGSS script host runs the project's own scripts (the default)
  // or the built-in flow does. Resolved from --rgss_script_host and the
  // RGSS_SCRIPT_HOST environment variable above, because the Ruby side cannot
  // read the environment in this build (RPGXP::ScriptHost.enabled?).
  mrb_const_set(M, mrb_obj_value(M->object_class),
                mrb_intern_lit(M, "RGSS_SCRIPT_HOST"),
                mrb_bool_value(FLAGS_rgss_script_host));
  mrb_const_set(M, mrb_obj_value(M->object_class),
                mrb_intern_lit(M, "MV_SCREENSHOT"),
                mrb_str_new_cstr(M, FLAGS_mv_screenshot.c_str()));
  mrb_const_set(M, mrb_obj_value(M->object_class),
                mrb_intern_lit(M, "MV_NEW_GAME"),
                mrb_bool_value(FLAGS_mv_new_game));
  mrb_const_set(M, mrb_obj_value(M->object_class),
                mrb_intern_lit(M, "MV_BATTLE_TEST"),
                mrb_fixnum_value(FLAGS_mv_battle_test));
  mrb_const_set(M, mrb_obj_value(M->object_class),
                mrb_intern_lit(M, "MV_MOVE_TEST"),
                mrb_bool_value(FLAGS_mv_move_test));
  mrb_const_set(M, mrb_obj_value(M->object_class),
                mrb_intern_lit(M, "MV_MESSAGE_TEST"),
                mrb_bool_value(FLAGS_mv_message_test));
  mrb_const_set(M, mrb_obj_value(M->object_class),
                mrb_intern_lit(M, "MV_MENU_TEST"),
                mrb_bool_value(FLAGS_mv_menu_test));
  mrb_const_set(M, mrb_obj_value(M->object_class),
                mrb_intern_lit(M, "MV_SAVE_TEST"),
                mrb_bool_value(FLAGS_mv_save_test));
  mrb_const_set(M, mrb_obj_value(M->object_class),
                mrb_intern_lit(M, "MV_AUDIO_TEST"),
                mrb_bool_value(FLAGS_mv_audio_test));
  mrb_const_set(M, mrb_obj_value(M->object_class),
                mrb_intern_lit(M, "MZ_NEW_GAME"),
                mrb_bool_value(FLAGS_mz_new_game));
  mrb_const_set(M, mrb_obj_value(M->object_class),
                mrb_intern_lit(M, "MZ_MOVE_TEST"),
                mrb_bool_value(FLAGS_mz_move_test));
  mrb_const_set(M, mrb_obj_value(M->object_class),
                mrb_intern_lit(M, "MZ_AUDIO_TEST"),
                mrb_bool_value(FLAGS_mz_audio_test));
  mrb_const_set(M, mrb_obj_value(M->object_class),
                mrb_intern_lit(M, "MZ_SCREENSHOT"),
                mrb_str_new_cstr(M, FLAGS_mz_screenshot.c_str()));
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
      fs::exists(game_dir_path / "Game.ini") || is_rpgvx_game(game_dir_path) ||
      (fs::exists(game_dir_path / "js" / "rpg_core.js") &&
       fs::exists(game_dir_path / "data" / "System.json")) ||
      (fs::exists(game_dir_path / "js" / "rmmz_core.js") &&
       fs::exists(game_dir_path / "data" / "System.json"))) {
    rpg_start_game();
  } else {
    std::fprintf(stderr,
                 "No project baked in; waiting for the page to load one "
                 "into /game.\n");
  }
  return EXIT_SUCCESS;
#else
  // The crash-report probe is the odd one out: it *wants* an exception, so it
  // cannot go through the "call it and CHECK_NO_EXC" shape below. It raises
  // through the real reporting path and reads the report back itself.
  if (FLAGS_error_dump_probe) {
    const int rc = error_dump_run_probe(M);
    rgss_audio_shutdown();
    gflags::ShutDownCommandLineFlags();
    return rc;
  }

  // The probes need the display, the audio backend and mruby, but no game: each
  // builds what it measures. Run them here, before the game-class dispatch, and
  // report through the exit code.
  const char* probe = FLAGS_rgss_effect_probe  ? "effect_probe"
                      : FLAGS_rgss_audio_probe ? "audio_probe"
                                               : nullptr;
  if (probe) {
    const mrb_value ok =
        mrb_funcall(M, mrb_obj_value(mrb_module_get(M, "RGSS")), probe, 0);
    CHECK_NO_EXC(M);
    rgss_audio_shutdown();
    gflags::ShutDownCommandLineFlags();
    return mrb_test(ok) ? EXIT_SUCCESS : EXIT_FAILURE;
  }

  mrb_value game_obj;
  // Record the detected maker for the crash report before the runtime is built
  // (see the same dispatch in rpg_start_game above).
  if (fs::exists(game_dir_path / "RPG_RT.ldb")) {
    error_dump_set_context("project", "RPG Maker 2000/2003 (RPG_RT.ldb)");
    game_obj = mrb_obj_new(M, mrb_class_get(M, "RPG2k"), 1, &args);
  } else if (fs::exists(game_dir_path / "js" / "rmmz_core.js") &&
             fs::exists(game_dir_path / "data" / "System.json")) {
    // RPG Maker MZ: a JavaScript game (js/rmmz_core.js) with a JSON database.
    // Shares MV's JS host but needs a WebGL backend (not built yet), so it
    // reports the pending state. See mruby-mvjs/mrblib/mz.rb, docs/adr/0004 M6.
    error_dump_set_context("project", "RPG Maker MZ (js/rmmz_core.js)");
    game_obj = mrb_obj_new(M, mrb_class_get(M, "MZ"), 1, &args);
  } else if (fs::exists(game_dir_path / "js" / "rpg_core.js") &&
             fs::exists(game_dir_path / "data" / "System.json")) {
    // RPG Maker MV: a JavaScript game (js/rpg_core.js) with a JSON database.
    // See docs/adr/0004-javascript-maker-mv-quickjs.md.
    error_dump_set_context("project", "RPG Maker MV (js/rpg_core.js)");
    game_obj = mrb_obj_new(M, mrb_class_get(M, "MV"), 1, &args);
  } else if (is_rpgvx_game(game_dir_path)) {
    // RPG Maker VX / VX Ace: a Marshal database like XP's under a different
    // extension (Data/*.rvdata[2]) and schema. Checked before the XP branch,
    // which only looks for Game.ini — a VX project has one too. The database
    // loads and the RGSS script host (the default path) runs the project's own
    // scripts; the built-in title/map flow is still to come, so a project that
    // ships no scripts — or a boot with RGSS_SCRIPT_HOST=0 — reports that. See
    // mruby-rpgvx and docs/adr/0024-rpgvx-rgss2-rgss3-data-layer.md.
    error_dump_set_context("project", "RPG Maker VX / VX Ace");
    game_obj = mrb_obj_new(M, mrb_class_get(M, "RPGVX"), 1, &args);
  } else if (fs::exists(game_dir_path / "Game.ini")) {
    error_dump_set_context("project", "RPG Maker XP (Game.ini)");
    game_obj = mrb_obj_new(M, mrb_class_get(M, "RPGXP"), 1, &args);
  } else {
    CHECK(false) << "Unknown game directory: " << game_dir_path;
  }
  CHECK_NO_EXC(M);

  mrb_funcall(M, game_obj, "start", 0);
  // The game ran to its end or died in it; either way this is the last chance
  // to report, so the exception goes out as a full report rather than as a
  // backtrace plus an ng-log abort.
  if (M->exc) {
    error_dump_report(M, "the running game");
    rgss_audio_shutdown();
    gflags::ShutDownCommandLineFlags();
    return EXIT_FAILURE;
  }

  rgss_audio_shutdown();
  gflags::ShutDownCommandLineFlags();

  return EXIT_SUCCESS;
#endif
}
