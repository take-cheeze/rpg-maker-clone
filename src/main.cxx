
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <functional>
#include <memory>
#include <regex>
#include <string>
#include <vector>

#include <SDL2/SDL.h>
#include <lvgl.h>
#include <mruby.h>
#include <mruby/array.h>
#include <mruby/compile.h>
#include <mruby/error.h>
#include <mruby/string.h>
#include <mruby/variable.h>

#include <gflags/gflags.h>
#include <ng-log/logging.h>
#include <inicpp.hpp>

#include "default_font.hxx"
#include "error_dump.hxx"
#include "iterm.hxx"
#include "log_bridge.hxx"
#include "log_console.hxx"
#include "profiler.hxx"
#include "sixel.hxx"
#include "terminal.hxx"
#include "window_title.hxx"

#ifdef __EMSCRIPTEN__
#include <emscripten.h>
#endif

#ifdef __ANDROID__
#include <android/log.h>
#include <pthread.h>
#include <unistd.h>
#endif

DEFINE_int64(timeout_ms, -1, "timeout to exit");
DEFINE_int64(width, 320, "width of the window");
DEFINE_int64(height, 240, "height of the window");
DEFINE_string(game_dir, "", "Game directory");
DEFINE_bool(
    test_play,
    false,
    "Explicitly mark this run as a Test Play launch, the same way the RPG "
    "Maker editors' own Test Play button does (Game.ini's [Game] Test=1 for "
    "RPG2000/2003, XP and VX/VX Ace projects is read automatically and does "
    "not need this). The engine's own debugging and CI-automation tooling "
    "-- --profile, --term_console, --term_stats, the --error_dump_probe / "
    "--rgss_effect_probe / --rgss_audio_probe ctest probes, and the "
    "--rpg2k_*/--rgss_host_*/--mv_*/--mz_* headless-drive flags -- only take "
    "effect when the run is in test play; a released game launched without "
    "Test=1 or --test_play ignores all of them");
DEFINE_string(
    mv_screenshot,
    "",
    "For RPG Maker MV: write a PNG of the rendered frame to this path "
    "after boot, then keep running (used to capture output in CI)");
DEFINE_bool(
    no_render_wait,
    false,
    "Skip RGSS::Graphics.update's real-time frame-pacing sleep (the wait "
    "that throttles the run to wall-clock 60fps), so a headless test-play "
    "run advances frames back-to-back as fast as the CPU allows instead of "
    "at real-play speed. Game logic is timed off Graphics.frame_count, not "
    "the wall clock, so this only removes idle wall-clock wait -- it does "
    "not change what any frame does. Used by the MV/MZ/RPG2k/XP boot-check "
    "smokes, which only need the frames to happen, not to happen on time.");
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
DEFINE_int32(
    rpg2k_preview_map,
    0,
    "For RPG Maker 2000/2003: once the title screen appears, auto-select New "
    "Game like --rpg2k_new_game, but start on this map id, centred on its "
    "middle tile, instead of the database's configured start position -- a "
    "quick way to inspect one map's rendering without a save file positioned "
    "there. Combine with --iterm (or --sixel) and --timeout_ms to dump the "
    "map to the terminal and exit. 0 disables the override (default; map ids "
    "start at 1)");
DEFINE_int32(
    rpg2k_battle_troop,
    0,
    "For RPG Maker 2000/2003: once the title screen appears, auto-select New "
    "Game like --rpg2k_new_game, then open a battle against this troop id from "
    "the database (a scripted Enemy Encounter with no encounter wiring in the "
    "project -- the 2003 test beds ship no encounters), logging the fight it "
    "reaches as [RPG2k-BATTLE]. Used to drive a real project into the battle "
    "scene headlessly so the 2003 battle path is exercised end to end; the "
    "fight then waits for input until the run times out. 0 disables it "
    "(default; troop ids start at 1)");
DEFINE_bool(
    rpg2k_map_editor,
    false,
    "For RPG Maker 2000/2003: once the title screen appears, auto-select New "
    "Game like --rpg2k_new_game, then push the F9 debug menu's Map viewer "
    "straight into its Edit mode (the in-game Map Editor) on top of the map, "
    "skipping navigating there through F9 by hand. Combine with "
    "--rpg2k_preview_map to choose which map opens, and with --iterm/--sixel "
    "and --timeout_ms for a headless screenshot. False disables it (default)");
DEFINE_bool(
    rpg2k_chipset_editor,
    false,
    "For RPG Maker 2000/2003: once the title screen appears, auto-select New "
    "Game like --rpg2k_new_game, then push the F9 debug menu's chipset "
    "passability editor for the starting map's chipset on top of the map. "
    "Combine with --rpg2k_preview_map to choose which map (and so which "
    "chipset) opens. False disables it (default)");
DEFINE_int32(
    rpg2k_preview_animation,
    0,
    "For RPG Maker 2000/2003: once the title screen appears, auto-select New "
    "Game like --rpg2k_new_game, then immediately play this database battle "
    "animation id back on the field map, screen-centred, the same way a "
    "battle round would -- a quick way to inspect one animation's frames and "
    "flashes without a save file positioned near an encounter, or a real "
    "fight, to trigger it. Combine with --iterm/--sixel and --timeout_ms to "
    "capture it headlessly. 0 disables it (default; animation ids start "
    "at 1)");
DEFINE_bool(
    rgss_script_host,
    true,
    "For the RGSS makers (XP / VX / VX Ace): run the project's own bundled "
    "scripts (Data/Scripts.rxdata, Scripts.rvdata[2]) the way RGSS104E.dll "
    "does. On by default, and the only way a game runs: there is no second "
    "engine, so --norgss_script_host merely loads the project and reports that "
    "it will not run it (docs/adr/0030-rgss-only-the-games-own-engine.md). The "
    "RGSS_SCRIPT_HOST "
    "environment variable seeds this flag (set it to 0/false/off/no to opt "
    "out); an explicit --rgss_script_host on the command line wins over it. "
    "See docs/adr/0029-rgss-script-host-by-default.md");
DEFINE_bool(
    rgss_host_new_game,
    false,
    "For the RGSS makers under the script host: tap the confirm key on the "
    "game's own title screen once a second, so a headless run gets into the "
    "game without a keyboard, and log each scene the game reaches as "
    "[RPGXP-HOST-SCENE]. A game shows its own title screen, so this is how a "
    "headless run gets past it. Used by scripts/rpgxp_boot_check.bash");
DEFINE_bool(
    rgss_host_move_test,
    false,
    "For the RGSS makers under the script host: once the game's own map scene "
    "is "
    "up, hold each direction in turn and log where the party started and ended "
    "as [RPGXP-HOST-MOVE] (implies --rgss_host_new_game to reach the map). The "
    "rung above reaching the map: a game whose own Game_Player reads "
    "Input.dir4 "
    "and steps across its own passability is being played, not just drawn. "
    "Used "
    "by scripts/rpgxp_boot_check.bash");
DEFINE_bool(
    rgss_host_menu_test,
    false,
    "For the RGSS makers under the script host: once the game is on its own "
    "map (and done walking, if --rgss_host_move_test is on too) press the "
    "cancel key and log which scene the game went to as [RPGXP-HOST-MENU] "
    "(implies --rgss_host_new_game). The rung above walking: a game's own menu "
    "is the first thing it draws out of its own Window classes, its own "
    "windowskin and its own font. Used by scripts/rpgxp_boot_check.bash");
DEFINE_bool(
    rgss_host_battle_test,
    false,
    "For the RGSS makers under the script host: once the game is on its own "
    "map, start a battle the way its own Battle Processing event command does "
    "(setting the same five $game_temp fields) and log which scene the game "
    "reached as [RPGXP-HOST-BATTLE] scene=.. reached=.. called=.. (implies "
    "--rgss_host_new_game). The rung above the menu: a battle builds the "
    "game's own Spriteset_Battle, so every enemy is a Sprite_Battler on top "
    "of RPG::Sprite. Unlike the other probes this writes to the game's "
    "globals, because no keypress starts a battle. called=false means the "
    "probe never got that far: the game's own Game_Temp does not implement "
    "the stock battle-calling attributes (a real game may replace Game_Temp "
    "entirely with a custom one, e.g. a custom battle system) -- distinct "
    "from called=true reached=false, where the battle really was requested "
    "but the game's own engine never brought Scene_Battle up. Used by "
    "scripts/rpgxp_boot_check.bash");
DEFINE_bool(
    rgss_host_save_test,
    false,
    "For the RGSS makers under the script host: once the game is on its own "
    "map, open its save screen the way its own Save Screen event command does "
    "(setting $game_temp.save_calling) and log whether it got there as "
    "[RPGXP-HOST-SAVE] (implies --rgss_host_new_game). This is the one place a "
    "game reads a file's timestamp back -- its Window_SaveFile stamps each "
    "slot "
    "from File#mtime -- and where its own save_data writes a real file. Used "
    "by "
    "scripts/rpgxp_boot_check.bash");
DEFINE_int64(
    rgss_random_seed,
    0,
    "For the RGSS makers under the script host: seed the random number "
    "generator with this value before the game's own scripts run, so a "
    "headless "
    "run drives the same game every time. mruby seeds from the clock, and a "
    "game's own engine rolls constantly -- encounter counts, damage variance, "
    "and the action order of a battle -- so without this a check that gets as "
    "far as a fight is a different fight on every run. 0 leaves the clock seed "
    "alone, which is what a player wants. Used by "
    "scripts/rpgxp_boot_check.bash");
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
DEFINE_bool(
    mz_message_test,
    false,
    "For RPG Maker MZ: once on the map, show a text message (implies "
    "--mz_new_game to reach the map) and log whether the message window "
    "opened, so a headless run confirms the message/window path renders. "
    "Used in CI");
DEFINE_bool(
    mz_animation_test,
    false,
    "For RPG Maker MZ: once on the map, play an animation on the player "
    "(implies --mz_new_game to reach the map) and log whether its cells "
    "actually drew, so a headless run confirms the animation path renders. MZ "
    "picks between two animation systems by data shape: an animation carrying "
    "a `frames` array draws as sprites (Sprite_AnimationMV), anything else "
    "goes to Effekseer, whose WASM runtime this host does not start. Used in "
    "CI");
DEFINE_bool(
    mz_equip_test,
    false,
    "For RPG Maker MZ: walk the party menu to Equip and put the test bed's "
    "weapon on (implies --mz_new_game to reach the map), then log whether the "
    "actor's attack went up with it. Scene_Equip is the last major scene "
    "nothing else here enters, and equipment is the one place a parameter is "
    "meant to change because of what an actor holds. Used in CI");
DEFINE_bool(
    mz_message_play,
    false,
    "For RPG Maker MZ: show a message and a choice on the map and operate "
    "them — page the text through, move the cursor to the second choice and "
    "confirm it — then log which branch of the event actually ran. The message "
    "probe only asserts that a window opened; this covers the window taking "
    "input, closing again, and the interpreter branching on the answer. "
    "Used in CI");
DEFINE_bool(
    mz_shop_test,
    false,
    "For RPG Maker MZ: open a shop from the map with a Shop Processing command "
    "and buy something in it (implies --mz_new_game to reach the map), then "
    "log whether the gold was spent and the item arrived. Scene_Shop is a "
    "scene nothing else here enters, and the only place the engine spends "
    "gold against a price list rather than an event handing items over. "
    "Used in CI");
DEFINE_bool(
    mz_encounter_test,
    false,
    "For RPG Maker MZ: transfer to the test bed's second map and walk until a "
    "*random encounter* starts a battle by itself (implies --mz_new_game to "
    "reach the map), then log whether one fired and which troop it picked. "
    "Every other battle here is started by a Battle Processing command — a "
    "game telling the engine to fight; this is the engine deciding to, through "
    "the map's own encounter list. Used in CI");
DEFINE_bool(
    mz_common_event_test,
    false,
    "For RPG Maker MZ: once on the map, turn on the switch the test bed's "
    "parallel common event is gated on and call its other common event by id "
    "(implies --mz_new_game to reach the map), then log whether each one ran. "
    "They are separate engine paths — a parallel common event runs on an "
    "interpreter Game_CommonEvent owns, a called one on a child interpreter "
    "nested inside the caller — and an empty CommonEvents.json left both "
    "unexercised. Used in CI");
DEFINE_bool(
    mz_transfer_test,
    false,
    "For RPG Maker MZ: once on the map, run a Transfer Player command to the "
    "test bed's second map (implies --mz_new_game to reach the map) and log "
    "whether the destination actually loaded — its map id, the tile the player "
    "landed on, and whether the arriving map's own events are running. A bed "
    "with one map never loads a second one, so nothing else here covers "
    "DataManager.loadMapData or Scene_Map re-creating itself. Used in CI");
DEFINE_bool(
    mz_menu_test,
    false,
    "For RPG Maker MZ: once on the map, open the party menu (implies "
    "--mz_new_game to reach the map) and log whether Scene_Menu opened, so a "
    "headless run confirms the menu path works. Used in CI");
DEFINE_bool(
    mz_menu_play,
    false,
    "For RPG Maker MZ: once the menu --mz_menu_test opens, use it — walk the "
    "command window to Item, pick the party's healing item, pick the wounded "
    "actor, and back out to the map — and log whether the item actually "
    "healed and was consumed. Opening Scene_Menu says the scene was "
    "constructed, not that the menu works; this covers what lies between. "
    "Implies --mz_menu_test. Used in CI");
DEFINE_bool(
    mz_save_test,
    false,
    "For RPG Maker MZ: once on the map, save to a slot and load it back "
    "(implies --mz_new_game to reach the map) and log whether the save/load "
    "round-trip succeeded, so a headless run confirms the save path works. "
    "MZ's save chain is asynchronous, so the result is reported once it "
    "settles. Used in CI");
DEFINE_int32(
    mz_battle_test,
    0,
    "For RPG Maker MZ: once on the map, start a battle against this troop id "
    "(implies --mz_new_game to reach the map) and log whether Scene_Battle was "
    "reached, so a headless run confirms the combat entry path works. 0 "
    "disables. Used in CI");
DEFINE_bool(
    mz_battle_play,
    false,
    "For RPG Maker MZ: once in the battle --mz_battle_test starts, play it out "
    "— tap confirm through the party/actor command windows and the target "
    "selection until the enemy's HP falls and the battle hands back to the "
    "map — and log whether the fight actually resolved. Reaching Scene_Battle "
    "is a much smaller claim than combat working; this covers what lies "
    "between. Implies --mz_battle_test (troop 1 unless one is named). Used in "
    "CI");
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
DEFINE_bool(
    zundamon_tts,
    false,
    "Read the rpg2k message window's text aloud in Zundamon (ずんだもん)'s "
    "voice as each Show Text/Show Choices page opens, via a bundled offline "
    "VOICEVOX CORE synthesis stack (RGSS::Tts, src/voicevox_tts.cxx). Off by "
    "default: the stack is ~90 MiB and not committed, so run "
    "scripts/download-voicevox-zundamon.bash first -- with no assets/voicevox "
    "installed this flag logs why and the game runs silently, same as "
    "--zundamon_tts on a build with no VOICEVOX CORE backend at all (see "
    "RGSS::Tts.available?)");
DEFINE_int32(
    zundamon_tts_style,
    3,
    "Which of Zundamon's four bundled styles --zundamon_tts speaks in: 3 "
    "ノーマル/normal (default), 1 あまあま/sweet, 7 ツンツン/curt, 5 "
    "セクシー/sultry. Reaching a different VOICEVOX character entirely needs "
    "its own downloaded voice model, which scripts/download-voicevox-"
    "zundamon.bash does not fetch.");
DEFINE_double(zundamon_tts_speed,
              1.0,
              "--zundamon_tts speech rate. VOICEVOX's own neutral value is "
              "1.0; roughly 0.5-2.0 stays intelligible.");
DEFINE_double(zundamon_tts_pitch,
              0.0,
              "--zundamon_tts pitch shift. VOICEVOX's own neutral value is "
              "0.0; roughly -0.15-0.15 stays intelligible.");
DEFINE_double(
    zundamon_tts_intonation,
    1.0,
    "--zundamon_tts intonation (pitch variation) strength. VOICEVOX's own "
    "neutral value is 1.0; 0 is flat/monotone, higher is more exaggerated.");
DEFINE_double(zundamon_tts_volume,
              1.0,
              "--zundamon_tts loudness, independent of the SE/BGM volumes "
              "Play SE/Play BGM set. VOICEVOX's own neutral value is 1.0.");
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
DEFINE_string(script, "", "Runs ruby script directly as entry point");

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

// The RPG Maker editors (2000/2003, XP, VX/VX Ace) write `Test=1` into a
// project's own Game.ini for the duration of a Test Play launch and strip it
// again for a real build, so it is the authentic on-disk signal that this run
// is a playtest rather than a released game -- unlike the CLI, which anyone
// launching the binary controls either way. MV/MZ projects carry no Game.ini
// at all; --test_play is the only signal for those.
bool game_ini_test_flag(const fs::path& game_dir) {
  const fs::path ini_path = game_dir / "Game.ini";
  if (!fs::exists(ini_path))
    return false;
  inicpp::IniManager ini(ini_path.string());
  return ini["Game"].toInt("Test") != 0;
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
void init_default_font(const std::string& launch_dir) {
  // Installed layout first, then the source tree, the same order sdl_audio.cxx
  // probes for the patch set.
  rgss::add_default_font_dir(RGSS_DEFAULT_FONT_INSTALL_DIR);
  rgss::add_default_font_dir(RGSS_DEFAULT_FONT_SOURCE_DIR);
  // The font search's last resort is the *relative* "assets/fonts", for a run
  // from the source tree or from beside an unpacked build. An RGSS boot has
  // since moved into the game's own directory (see the chdir in main), where
  // that would look for the game's fonts instead, so the launch directory is
  // added here as an absolute path -- after the configure-time ones, which keep
  // their priority.
  if (!launch_dir.empty())
    rgss::add_default_font_dir(
        (fs::path(launch_dir) / "assets" / "fonts").string());

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

#ifdef __ANDROID__
// Draws the visible virtual gamepad (src/android_vpad_ui.cxx) on LVGL's top
// layer and centres the game picture in the phone-shaped window. Android-only:
// desktop windows have keyboards and the browser page draws its own keypad in
// HTML (src/shell.html). Takes the game's own resolution, which the window is
// not (Android's is the phone screen), so the overlay knows the letterbox.
extern "C" void rgss_vpad_overlay_init(int game_w, int game_h);
#endif

// Opens the audio device and installs the SDL_mixer backend for RGSS::Audio
// (src/sdl_audio.cxx). A no-op if audio cannot be initialised. rgss_audio_
// shutdown tears it down on the native exit path.
extern "C" void rgss_audio_init(void);
extern "C" void rgss_audio_shutdown(void);

// Loads the VOICEVOX CORE synthesis stack and installs the RGSS::Tts backend
// for Zundamon message-window narration (src/voicevox_tts.cxx). Only called
// when --zundamon_tts is passed; a no-op (RGSS::Tts.available? stays false)
// if the assets are missing or this build has no backend at all. Always safe
// to call rgss_tts_shutdown, even when init was never called. style_id
// chooses among Zundamon's bundled styles; the four scales tune speed,
// pitch, intonation and volume (VOICEVOX's own neutral values: 1.0, 0.0,
// 1.0, 1.0) -- see --zundamon_tts_style/_speed/_pitch/_intonation/_volume.
extern "C" void rgss_tts_init(int style_id,
                              double speed_scale,
                              double pitch_scale,
                              double intonation_scale,
                              double volume_scale);
extern "C" void rgss_tts_shutdown(void);

// Whether the pending mruby exception is the game ending on purpose rather than
// failing: `exit` raises SystemExit, which mruby tags with MRB_EXC_EXIT. Both
// built-in title screens offer a Shutdown entry that calls it, and RMXP's own
// Interpreter uses it to abort a runaway common event.
//
// It is checked before every report because SystemExit is an Exception, not a
// StandardError, so none of the runtime's own `rescue` clauses stop it: picking
// Shutdown reached the top of the frame loop and printed a full crash report,
// telling a player who had just quit that the engine had died and asking them
// to file a bug (which is how this was found).
//
// True when that is what is pending, with the status `exit` was given written
// to *status (EXIT_SUCCESS for a plain `exit`); false for a real error, and for
// no exception at all.
static bool pending_exit(mrb_state* M, int* status) {
  if (M->exc == nullptr || !MRB_EXC_EXIT_P(M->exc))
    return false;
  // `exit` stores the status it was given in the exception's @status. Read it
  // directly rather than through MRB_EXC_EXIT_STATUS, whose mrb_as_int would
  // raise on a hand-raised SystemExit carrying something else -- while an
  // exception is already pending.
  const mrb_value v =
      mrb_iv_get(M, mrb_obj_value(M->exc), mrb_intern_lit(M, "status"));
  *status = mrb_integer_p(v) ? static_cast<int>(mrb_integer(v)) : EXIT_SUCCESS;
  return true;
}

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
    // was created at the 320x240 default. Resize it now, before the runtime
    // builds any screen-sized object: with a 320x240 canvas the XP scenes draw
    // off the edge -- the title's command window lands past the bottom and its
    // centred text past the right (found by the browser check that ADR 0025 has
    // since dropped; see docs/adr/0025). The canvas follows the new resolution
    // (LVGL resizes the SDL window on a resolution change) and the page
    // rescales it from there; the browser display is never zoomed, see main()
    // below.
    if (em_display) {
      lv_display_set_resolution(em_display.get(), RPGXP_WIDTH, RPGXP_HEIGHT);
      LOG(INFO) << "RPGXP: display sized to " << RPGXP_WIDTH << "x"
                << RPGXP_HEIGHT;
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
    LOG(ERROR) << "No RPG2k (RPG_RT.ldb), RPG XP (Game.ini), RPG Maker VX / VX "
                  "Ace (Data/System.rvdata[2]), RPG Maker MV "
                  "(js/rpg_core.js + data/System.json) or RPG Maker MZ "
                  "(js/rmmz_core.js + data/System.json) project found under "
                  "/game";
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
      int status = EXIT_SUCCESS;
      if (pending_exit(M, &status)) {
        // The player quit (the title screen's Shutdown entry). Drop the pending
        // SystemExit and stop driving frames; the tab keeps the last frame on
        // the canvas, since there is no process to end here.
        M->exc = nullptr;
        LOG(INFO) << "The game exited (status " << status << ").";
      } else {
        error_dump_report(M, "the frame loop");
      }
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

// Every flag below is debugging or CI-automation tooling: a profiler, a
// terminal log/stats overlay, headless input-injection ("drive the game as if
// testing it") and the render/audio/error-report self-probes. None of it
// should be reachable against a released game -- one launched with neither
// Game.ini's own Test=1 nor an explicit --test_play -- no matter what is on
// its command line, so this resets each one to its default and says why
// whenever the run asked for it anyway. --rgss_script_host is deliberately
// not touched: it is not a debug feature but the only way an RGSS game runs
// at all (docs/adr/0029-rgss-script-host-by-default.md).
//
// --rpg2k_map_editor/--rpg2k_chipset_editor/--rpg2k_preview_animation are
// ALSO deliberately not touched, unlike every other flag here: a released
// game exposes them to nobody regardless (they only run once *some* CLI flag
// already launched them, same as --test_play itself would have to be), so
// the redundant --test_play a developer would otherwise have to keep retyping
// alongside them protects against nothing --test_play doesn't already cover
// on its own. The interactive path into the same tools -- pressing F9 during
// a normal play session -- stays fully gated on Scene::Map#try_open_debug_menu
// reading RPG2k#test_play, unaffected by this.
static void disable_non_test_play_flags() {
  auto reset_bool = [](bool& flag, const char* name) {
    if (flag) {
      LOG(ERROR) << "--" << name
                 << " is test-play-only tooling; ignoring outside test play "
                    "(no Game.ini [Game] Test=1 and no --test_play)";
      flag = false;
    }
  };
  auto reset_int = [](auto& flag, const char* name) {
    if (flag != 0) {
      LOG(ERROR) << "--" << name
                 << " is test-play-only tooling; ignoring outside test play "
                    "(no Game.ini [Game] Test=1 and no --test_play)";
      flag = 0;
    }
  };
  auto reset_string = [](std::string& flag, const char* name) {
    if (!flag.empty()) {
      LOG(ERROR) << "--" << name
                 << " is test-play-only tooling; ignoring outside test play "
                    "(no Game.ini [Game] Test=1 and no --test_play)";
      flag.clear();
    }
  };

  reset_bool(FLAGS_rpg2k_new_game, "rpg2k_new_game");
  reset_bool(FLAGS_rpg2k_continue, "rpg2k_continue");
  reset_int(FLAGS_rpg2k_preview_map, "rpg2k_preview_map");
  reset_int(FLAGS_rpg2k_battle_troop, "rpg2k_battle_troop");
  reset_bool(FLAGS_rgss_host_new_game, "rgss_host_new_game");
  reset_bool(FLAGS_rgss_host_move_test, "rgss_host_move_test");
  reset_bool(FLAGS_rgss_host_menu_test, "rgss_host_menu_test");
  reset_bool(FLAGS_rgss_host_battle_test, "rgss_host_battle_test");
  reset_bool(FLAGS_rgss_host_save_test, "rgss_host_save_test");
  reset_int(FLAGS_rgss_random_seed, "rgss_random_seed");
  reset_bool(FLAGS_mv_new_game, "mv_new_game");
  reset_int(FLAGS_mv_battle_test, "mv_battle_test");
  reset_bool(FLAGS_mv_move_test, "mv_move_test");
  reset_bool(FLAGS_mv_message_test, "mv_message_test");
  reset_bool(FLAGS_mv_menu_test, "mv_menu_test");
  reset_bool(FLAGS_mv_save_test, "mv_save_test");
  reset_bool(FLAGS_mv_audio_test, "mv_audio_test");
  reset_string(FLAGS_mv_screenshot, "mv_screenshot");
  reset_bool(FLAGS_no_render_wait, "no_render_wait");
  reset_bool(FLAGS_mz_new_game, "mz_new_game");
  reset_bool(FLAGS_mz_move_test, "mz_move_test");
  reset_bool(FLAGS_mz_audio_test, "mz_audio_test");
  reset_bool(FLAGS_mz_message_test, "mz_message_test");
  reset_bool(FLAGS_mz_animation_test, "mz_animation_test");
  reset_bool(FLAGS_mz_equip_test, "mz_equip_test");
  reset_bool(FLAGS_mz_message_play, "mz_message_play");
  reset_bool(FLAGS_mz_shop_test, "mz_shop_test");
  reset_bool(FLAGS_mz_encounter_test, "mz_encounter_test");
  reset_bool(FLAGS_mz_common_event_test, "mz_common_event_test");
  reset_bool(FLAGS_mz_transfer_test, "mz_transfer_test");
  reset_bool(FLAGS_mz_menu_test, "mz_menu_test");
  reset_bool(FLAGS_mz_menu_play, "mz_menu_play");
  reset_bool(FLAGS_mz_save_test, "mz_save_test");
  reset_int(FLAGS_mz_battle_test, "mz_battle_test");
  reset_bool(FLAGS_mz_battle_play, "mz_battle_play");
  reset_string(FLAGS_mz_screenshot, "mz_screenshot");
  reset_bool(FLAGS_rgss_effect_probe, "rgss_effect_probe");
  reset_bool(FLAGS_rgss_audio_probe, "rgss_audio_probe");
  reset_bool(FLAGS_error_dump_probe, "error_dump_probe");
  reset_bool(FLAGS_profile, "profile");
  reset_string(FLAGS_profile_trace, "profile_trace");

  // --term_console/--term_stats default to *on*, but only have any effect
  // once a terminal backend (--sixel/--iterm) is active; only warn when that
  // is actually the case, so an ordinary SDL-window launch stays quiet.
  if ((FLAGS_sixel || FLAGS_iterm) && (FLAGS_term_console || FLAGS_term_stats))
    LOG(ERROR) << "--term_console/--term_stats are test-play-only tooling; "
                  "disabled outside test play (no Game.ini [Game] Test=1 and "
                  "no --test_play)";
  FLAGS_term_console = false;
  FLAGS_term_stats = false;
}

#ifdef __ANDROID__
static void* android_stderr_bridge_thread(void* arg) {
  const int read_fd = *static_cast<int*>(arg);
  delete static_cast<int*>(arg);
  FILE* in = fdopen(read_fd, "r");
  if (!in)
    return nullptr;
  char* line = nullptr;
  size_t cap = 0;
  while (getline(&line, &cap, in) != -1) {
    const size_t len = strlen(line);
    if (len && line[len - 1] == '\n')
      line[len - 1] = '\0';
    __android_log_write(ANDROID_LOG_INFO, "RPG2K", line);
  }
  free(line);
  fclose(in);
  return nullptr;
}

static void android_stderr_bridge_install() {
  int fds[2];
  if (pipe(fds) != 0)
    return;
  auto* read_fd = new int(fds[0]);
  pthread_t thread;
  if (pthread_create(&thread, nullptr, android_stderr_bridge_thread, read_fd) !=
      0) {
    delete read_fd;
    close(fds[0]);
    close(fds[1]);
    return;
  }
  pthread_detach(thread);
  dup2(fds[1], STDERR_FILENO);
  close(fds[1]);
}
#endif

int main(int argc, char** argv) {
#ifdef __ANDROID__
  android_stderr_bridge_install();
#endif
  // Seed the script-host flag from the environment *before* parsing, so an
  // explicit --rgss_script_host on the command line still wins. The variable is
  // the documented opt-out and this mruby build has no ENV for the Ruby side to
  // read, so the native runtime resolves it and hands Ruby the answer as the
  // RGSS_SCRIPT_HOST constant below.
  if (const char* host_env = std::getenv("RGSS_SCRIPT_HOST"))
    if (*host_env != '\0')
      FLAGS_rgss_script_host = script_host_env_enabled(host_env);

  // Parse a copy, not argv itself. ParseCommandLineFlags's remove_flags=true
  // fixup (3rd/gflags/src/gflags.cc) does `(*argv)[first_nonopt-1] =
  // (*argv)[0]` to compact flags out of the array in place -- duplicating
  // argv[0]'s pointer into a later slot rather than shifting every element.
  // Harmless wherever argv came from the OS/libc, which never frees it, but
  // fatal on Android: SDL's own JNI glue synthesizes this argv from Java
  // (nativeRunMain, 3rd/SDL/src/core/android/SDL_android.c) and frees every
  // element itself once main() returns, still counting up to its own
  // original (larger) argc -- so it frees that duplicated pointer twice.
  // Confirmed with AddressSanitizer on a real device (double-free, both
  // stacks landing on this exact SDL_strdup/SDL_free pair) after
  // docs/adr/0058-android-port.md's android-smoke investigation had chased
  // Scudo's downstream, much-later abort through several false leads
  // (an audio backend race, a report-file write) that never survived
  // testing. The copy's backing storage outlives this function (a local
  // std::vector, not touched again after this block), so nothing downstream
  // needs to change.
  std::vector<char*> argv_copy(argv,
                               argv + argc + 1);  // + argv[argc] == nullptr
  int parse_argc = argc;
  char** parse_argv = argv_copy.data();
  gflags::ParseCommandLineFlags(&parse_argc, &parse_argv, true);
  argc = parse_argc;
  argv = parse_argv;
  if (FLAGS_game_dir.empty()) {
#ifdef __EMSCRIPTEN__
    // A game directory is baked into the virtual filesystem at /game (see the
    // WASM_GAME_DIR option in CMakeLists.txt).
    FLAGS_game_dir = "/game";
#else
    FLAGS_game_dir = fs::current_path();
#endif
  }
  // Resolve it to an absolute path before anything reads it. Everything
  // downstream treats the game directory as a base -- the data loaders, the
  // asset search, the archive, the GAME_DIR constant handed to Ruby -- and the
  // chdir below would otherwise pull a relative one out from under them.
  {
    std::error_code ec;
    const fs::path absolute = fs::absolute(FLAGS_game_dir, ec);
    if (!ec)
      FLAGS_game_dir = absolute.lexically_normal().string();
  }
  nglog::InitializeLogging(argv[0]);
  // Before error_dump_install below tees $stderr through RGSS::ErrorReport,
  // so the very first buffered line already reaches ng-log too. See
  // include/terminal.hxx's "Stderr log bridge" section.
  log_bridge_install();

  // Whether this run is a Test Play launch: either the project's own
  // Game.ini says so (the RPG Maker editors' own signal, for 2000/2003, XP
  // and VX/VX Ace projects) or --test_play was passed explicitly (the only
  // signal available for MV/MZ projects, which carry no Game.ini, and for CI).
  // A released game launched plainly has neither, so the debugging and
  // CI-automation flags below all stay off for it regardless of what else is
  // on the command line.
  const bool is_test_mode =
      FLAGS_test_play || game_ini_test_flag(FLAGS_game_dir);
  if (!is_test_mode)
    disable_non_test_play_flags();

#ifdef __EMSCRIPTEN__
  // The page has no terminal and no log file anyone can reach: ng-log's files
  // land in the in-memory filesystem and vanish with the tab. Its on-screen log
  // panel mirrors stdout/stderr (Module.print / printErr in src/shell.html),
  // and ng-log only writes ERROR and above there by default -- which hid the
  // warnings that explain a *silent* failure, a page built without the MIDI
  // patch set being the one that cost the most to diagnose. Mirror warnings
  // too, so the page says why rather than just going quiet.
  nglog::SetStderrLogging(nglog::NGLOG_WARNING);
#endif

  // RPG Maker XP projects render at 640x480 and VX / VX Ace ones at 544x416
  // (RPG2000/MV use 320x240). When the window size was not overridden on the
  // command line, size the canvas to the detected maker's resolution so its
  // title and maps fill the screen. Detection mirrors the game-class dispatch
  // below: VX first (its archives, .rgss2a / .rgss3a, are *not* XP markers),
  // then Game.ini plus either a loose Data/System.rxdata or an XP archive,
  // since a packed release ships no loose Data/ folder.
  const bool xp_game = is_xp_game(FLAGS_game_dir);
  const bool vx_game = is_rpgvx_game(FLAGS_game_dir);
  {
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

  // Where the engine was launched from, captured before the chdir below: the
  // font search's relative fallback is resolved against it (init_default_font).
  std::string launch_dir;
  {
    std::error_code ec;
    const fs::path cwd = fs::current_path(ec);
    if (!ec)
      launch_dir = cwd.string();
  }

  // Run an RGSS game from its own directory, as the runtime it imitates does.
  //
  // A game's own scripts do relative file I/O and nothing tells them where they
  // are: the stock Scene_Save writes `File.open("Save1.rxdata", "wb")` and the
  // stock Scene_Title asks `FileTest.exist?("Save1.rxdata")` -- bare names,
  // resolved against the working directory. RGSS104E.dll never has to think
  // about it because Game.exe is launched from the game's folder, so that
  // directory *is* the game's. This engine is launched from anywhere with
  // --game_dir pointing elsewhere, so without this every game's saves land in
  // one shared place; scripts/rpgxp_boot_check.bash caught the consequence when
  // Pray for You's own title screen offered Continue on the strength of the
  // editor test bed's save file, read it as its own and died on the mismatch
  // (docs/rpgxp-rgss-api-gap.md, gap 0j). Two games overwriting each other's
  // progress is the same bug with a player in the chair.
  //
  // The RGSS makers only. The MV/MZ smokes write screenshots to paths relative
  // to wherever they were invoked, and an LCF game's saves are written by this
  // engine's own code against the game directory already, so neither needs it
  // and both would be disturbed by it.
  if (xp_game || vx_game) {
    std::error_code ec;
    fs::current_path(fs::path(FLAGS_game_dir), ec);
    if (ec)
      LOG(WARNING) << "could not run from the game directory '"
                   << FLAGS_game_dir << "': " << ec.message()
                   << "; the game's saves will land in the working directory "
                      "instead, where another game may find them";
  }

  // Everything a crash report should say about this run but cannot work out
  // for itself. Recorded before anything can fail, so even a failure during
  // start-up carries it (see include/error_dump.hxx).
  error_dump_set_context("game dir", FLAGS_game_dir);
  // Where relative paths in this run resolve — the game's own directory for an
  // RGSS boot (see the chdir above), which is also where its saves and this
  // report land, so a report can be found rather than guessed at.
  {
    std::error_code ec;
    const fs::path cwd = fs::current_path(ec);
    if (!ec)
      error_dump_set_context("working dir", cwd.string());
  }
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
    // RPG2000/2003, XP, VX(Ace) and MV all draw through LVGL's own software
    // rasteriser (LV_SDL_ACCELERATED 0 in lv_conf.h asks SDL for
    // SDL_RENDERER_SOFTWARE, not SDL_RENDERER_ACCELERATED -- except on
    // Android, which wants the GPU present path, see below); only MZ's WebGL
    // backend needs a real GL context, and that is a wholly separate
    // off-screen EGL context in mruby-mvjs/src/mvgl.cxx, never this window.
    // SDL_HINT_RENDER_DRIVER alone is not enough on SDL3 (reached here via
    // sdl2-compat): lv_sdl_sw.c's software renderer still calls
    // SDL_GetWindowSurface() to present, and that call spins up its own
    // *second*, GPU-accelerated companion renderer via SDL_CreateWindowTexture
    // -- ignoring the driver hint above -- which tries "opengl" first and
    // crashed with a fatal X_GLXMakeCurrent (GLXBadContext) error on an X
    // server with no working GLX. SDL_HINT_FRAMEBUFFER_ACCELERATION=0 turns
    // that companion renderer off, so SDL_GetWindowSurface() falls back to a
    // plain CPU blit instead -- see issue #449.
    //
    // That "plain CPU blit" only exists where the video backend implements a
    // window framebuffer of its own (X11 has the XImage/MIT-SHM path, Wayland
    // the wl_shm one, and Emscripten its canvas one). SDL3's Cocoa backend has
    // none: SDL_GetWindowSurface() there can *only* go through
    // SDL_CreateWindowTexture, so switching the companion renderer off leaves
    // it with nothing and the software renderer fails to come up at all
    // ("Window framebuffer support not available"), taking the CHECK below and
    // the whole process with it. Keep the #449 workaround off macOS.
    //
    // Android has the identical gap (confirmed on-device, arm64-v8a):
    // src/video/android/ never implements CreateWindowFramebuffer, so
    // SDL_CreateWindowTexture is the *only* window-framebuffer path there too
    // -- there is no XImage/wl_shm-style native one to fall back to. Keep the
    // #449 workaround off Android for the same reason it is already off
    // macOS.
    //
    // Android also skips the software-driver hint: lv_conf.h builds LVGL's
    // SDL backend with LV_SDL_ACCELERATED 1 there (the software present path
    // measured ~63ms a frame on-device -- see lv_conf.h), and an
    // SDL_RENDERER_ACCELERATED request must not be steered back to the
    // software driver by this hint.
#ifndef __ANDROID__
    SDL_SetHint(SDL_HINT_RENDER_DRIVER, "software");
#endif
#if !defined(__APPLE__) && !defined(__ANDROID__)
    SDL_SetHint(SDL_HINT_FRAMEBUFFER_ACCELERATION, "0");
#endif
    display = std::shared_ptr<lv_display_t>(
        lv_sdl_window_create(FLAGS_width, FLAGS_height),
        [](lv_display_t*) { lv_sdl_quit(); });
    CHECK(display);
    lv_sdl_window_set_resizeable(display.get(), false);
    // A 640x480 (XP) window is already large, so present it 1:1; the smaller
    // 320x240 (RPG2000/MV) one is doubled to a comfortable size.
    //
    // Not in the browser: there the page does the zooming (src/shell.html sizes
    // the canvas in CSS, with image-rendering: pixelated for the same
    // nearest-neighbour look), so the display keeps lv_sdl_window's default 1:1
    // and the canvas keeps the game's own resolution. LVGL's zoom only enlarges
    // the SDL window, leaving the software renderer to stretch every frame on
    // the CPU (lv_sdl_sw.c presents with SDL_RenderCopy into the zoom-sized
    // window) and to hand the canvas four times the pixels at 2x -- work the
    // browser does for free. It also keeps SDL's window pixels equal to game
    // pixels, which is what the pointer bridge in src/sdl_input.cxx assumes.
#ifndef __EMSCRIPTEN__
    lv_sdl_window_set_zoom(display.get(), FLAGS_width >= 640 ? 1.f : 2.f);
#endif
    // Name the window: this one titles it for the run, and every maker's boot
    // replaces that with the loaded game's own title through
    // RGSS.window_title= (see include/terminal.hxx's "Window title bridge").
    window_title_install(display.get());
    // SDL is initialised by lv_sdl_window_create above; install the keyboard
    // watch now so key events reach RGSS::Input.
    rgss_sdl_input_init();
#ifdef __ANDROID__
    // The display exists now, so the pad can size itself off the resolution
    // and the game root can be centred in the window.
    rgss_vpad_overlay_init(FLAGS_width, FLAGS_height);
#endif
  }

  // Bring up audio for every backend (SDL_mixer initialises the SDL audio
  // subsystem itself, so this works under the terminal backends too).
  rgss_audio_init();

  // Zundamon message-window narration, opt-in: loading the VOICEVOX CORE
  // stack costs real disk IO and an ONNX Runtime session, so it only happens
  // when actually asked for. Needs rgss_audio_init above to have opened the
  // SDL_mixer device first -- src/voicevox_tts.cxx plays through it.
  if (FLAGS_zundamon_tts)
    rgss_tts_init(FLAGS_zundamon_tts_style, FLAGS_zundamon_tts_speed,
                  FLAGS_zundamon_tts_pitch, FLAGS_zundamon_tts_intonation,
                  FLAGS_zundamon_tts_volume);

  // Before any game runs, so the first window drawn already has its font.
  init_default_font(launch_dir);

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
  // Whether this run is a Test Play launch (Game.ini's own Test=1, or
  // --test_play): the one native-side signal every maker's Ruby can consult,
  // the same way RPG2000/2003's own `TestPlay` launch word or MV/MZ's
  // `Utils.isOptionValid('test')` would.
  mrb_const_set(M, mrb_obj_value(M->object_class),
                mrb_intern_lit(M, "TEST_PLAY"), mrb_bool_value(is_test_mode));
  // See --no_render_wait above: read once here, the same way TIMEOUT_MS is,
  // by RGSS::Graphics.update (mruby-rgss/src/lib.cxx) to skip its real-time
  // frame-pacing sleep.
  mrb_const_set(M, mrb_obj_value(M->object_class),
                mrb_intern_lit(M, "NO_RENDER_WAIT"),
                mrb_bool_value(FLAGS_no_render_wait));
  mrb_const_set(M, mrb_obj_value(M->object_class),
                mrb_intern_lit(M, "RPG2K_NEW_GAME"),
                mrb_bool_value(FLAGS_rpg2k_new_game));
  mrb_const_set(M, mrb_obj_value(M->object_class),
                mrb_intern_lit(M, "RPG2K_CONTINUE"),
                mrb_bool_value(FLAGS_rpg2k_continue));
  // --rpg2k_preview_map: the map id RPG2k#start_new_game (mruby-rpg2k) should
  // jump New Game to instead of the database's configured start position, or 0
  // when unset. See the flag's own definition above for the map-preview use
  // case.
  mrb_const_set(M, mrb_obj_value(M->object_class),
                mrb_intern_lit(M, "RPG2K_PREVIEW_MAP"),
                mrb_fixnum_value(FLAGS_rpg2k_preview_map));
  // --rpg2k_battle_troop: the troop id RPG2k#start_new_game (mruby-rpg2k)
  // should open a headless battle against once the map is up, or 0 when
  // unset. See the flag's own definition above.
  mrb_const_set(M, mrb_obj_value(M->object_class),
                mrb_intern_lit(M, "RPG2K_BATTLE_TROOP"),
                mrb_fixnum_value(FLAGS_rpg2k_battle_troop));
  // --rpg2k_map_editor / --rpg2k_chipset_editor / --rpg2k_preview_animation:
  // RPG2k#start_new_game opens the named debug tool once the map is up. See
  // each flag's own definition above.
  mrb_const_set(M, mrb_obj_value(M->object_class),
                mrb_intern_lit(M, "RPG2K_MAP_EDITOR"),
                mrb_bool_value(FLAGS_rpg2k_map_editor));
  mrb_const_set(M, mrb_obj_value(M->object_class),
                mrb_intern_lit(M, "RPG2K_CHIPSET_EDITOR"),
                mrb_bool_value(FLAGS_rpg2k_chipset_editor));
  mrb_const_set(M, mrb_obj_value(M->object_class),
                mrb_intern_lit(M, "RPG2K_PREVIEW_ANIMATION"),
                mrb_fixnum_value(FLAGS_rpg2k_preview_animation));
  // The screen size actually configured for this run -- FLAGS_width/height,
  // already finalized above (the XP/VX auto-detect override, if the command
  // line didn't set either flag itself). Scene::MapViewer reads this to fill
  // whatever window the user asked for rather than sitting in a fixed
  // 320x240 corner of it; see Scene::Base#screen_width's own comment for why
  // that's safe for a debug-only tool where real gameplay scenes can't do
  // the same.
  mrb_const_set(M, mrb_obj_value(M->object_class),
                mrb_intern_lit(M, "RPG2K_SCREEN_WIDTH"),
                mrb_fixnum_value(FLAGS_width));
  mrb_const_set(M, mrb_obj_value(M->object_class),
                mrb_intern_lit(M, "RPG2K_SCREEN_HEIGHT"),
                mrb_fixnum_value(FLAGS_height));
  // Whether the RGSS script host runs the project's own scripts (the default)
  // or the built-in flow does. Resolved from --rgss_script_host and the
  // RGSS_SCRIPT_HOST environment variable above, because the Ruby side cannot
  // read the environment in this build (RPGXP::ScriptHost.enabled?).
  mrb_const_set(M, mrb_obj_value(M->object_class),
                mrb_intern_lit(M, "RGSS_SCRIPT_HOST"),
                mrb_bool_value(FLAGS_rgss_script_host));
  // Whether the script host taps confirm on the game's own title screen (see
  // RPGXP::ScriptHost.watch_frame).
  // The move and menu probes imply the confirm tap: both have to get onto a map
  // first, which means getting off the game's own title screen.
  mrb_const_set(
      M, mrb_obj_value(M->object_class),
      mrb_intern_lit(M, "RGSS_HOST_NEW_GAME"),
      mrb_bool_value(FLAGS_rgss_host_new_game || FLAGS_rgss_host_move_test ||
                     FLAGS_rgss_host_menu_test || FLAGS_rgss_host_battle_test ||
                     FLAGS_rgss_host_save_test));
  mrb_const_set(M, mrb_obj_value(M->object_class),
                mrb_intern_lit(M, "RGSS_HOST_MOVE_TEST"),
                mrb_bool_value(FLAGS_rgss_host_move_test));
  mrb_const_set(M, mrb_obj_value(M->object_class),
                mrb_intern_lit(M, "RGSS_HOST_MENU_TEST"),
                mrb_bool_value(FLAGS_rgss_host_menu_test));
  mrb_const_set(M, mrb_obj_value(M->object_class),
                mrb_intern_lit(M, "RGSS_HOST_BATTLE_TEST"),
                mrb_bool_value(FLAGS_rgss_host_battle_test));
  mrb_const_set(M, mrb_obj_value(M->object_class),
                mrb_intern_lit(M, "RGSS_HOST_SAVE_TEST"),
                mrb_bool_value(FLAGS_rgss_host_save_test));
  mrb_const_set(M, mrb_obj_value(M->object_class),
                mrb_intern_lit(M, "RGSS_RANDOM_SEED"),
                mrb_fixnum_value(FLAGS_rgss_random_seed));
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
                mrb_intern_lit(M, "MZ_MESSAGE_TEST"),
                mrb_bool_value(FLAGS_mz_message_test));
  mrb_const_set(M, mrb_obj_value(M->object_class),
                mrb_intern_lit(M, "MZ_ANIMATION_TEST"),
                mrb_bool_value(FLAGS_mz_animation_test));
  mrb_const_set(M, mrb_obj_value(M->object_class),
                mrb_intern_lit(M, "MZ_EQUIP_TEST"),
                mrb_bool_value(FLAGS_mz_equip_test));
  mrb_const_set(M, mrb_obj_value(M->object_class),
                mrb_intern_lit(M, "MZ_MESSAGE_PLAY"),
                mrb_bool_value(FLAGS_mz_message_play));
  mrb_const_set(M, mrb_obj_value(M->object_class),
                mrb_intern_lit(M, "MZ_SHOP_TEST"),
                mrb_bool_value(FLAGS_mz_shop_test));
  mrb_const_set(M, mrb_obj_value(M->object_class),
                mrb_intern_lit(M, "MZ_ENCOUNTER_TEST"),
                mrb_bool_value(FLAGS_mz_encounter_test));
  mrb_const_set(M, mrb_obj_value(M->object_class),
                mrb_intern_lit(M, "MZ_COMMON_EVENT_TEST"),
                mrb_bool_value(FLAGS_mz_common_event_test));
  mrb_const_set(M, mrb_obj_value(M->object_class),
                mrb_intern_lit(M, "MZ_TRANSFER_TEST"),
                mrb_bool_value(FLAGS_mz_transfer_test));
  mrb_const_set(M, mrb_obj_value(M->object_class),
                mrb_intern_lit(M, "MZ_MENU_TEST"),
                mrb_bool_value(FLAGS_mz_menu_test));
  mrb_const_set(M, mrb_obj_value(M->object_class),
                mrb_intern_lit(M, "MZ_MENU_PLAY"),
                mrb_bool_value(FLAGS_mz_menu_play));
  mrb_const_set(M, mrb_obj_value(M->object_class),
                mrb_intern_lit(M, "MZ_SAVE_TEST"),
                mrb_bool_value(FLAGS_mz_save_test));
  mrb_const_set(M, mrb_obj_value(M->object_class),
                mrb_intern_lit(M, "MZ_BATTLE_TEST"),
                mrb_fixnum_value(FLAGS_mz_battle_test));
  mrb_const_set(M, mrb_obj_value(M->object_class),
                mrb_intern_lit(M, "MZ_BATTLE_PLAY"),
                mrb_bool_value(FLAGS_mz_battle_play));
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
  CHECK(FLAGS_script.empty()) << "--script not supported on emscripten";
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
    LOG(INFO) << "No project baked in; waiting for the page to load one "
                 "into /game.";
  }
  return EXIT_SUCCESS;
#else
  // The crash-report probe is the odd one out: it *wants* an exception, so it
  // cannot go through the "call it and CHECK_NO_EXC" shape below. It raises
  // through the real reporting path and reads the report back itself.
  if (FLAGS_error_dump_probe) {
    const int rc = error_dump_run_probe(M);
    rgss_tts_shutdown();
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
    rgss_tts_shutdown();
    rgss_audio_shutdown();
    gflags::ShutDownCommandLineFlags();
    return mrb_test(ok) ? EXIT_SUCCESS : EXIT_FAILURE;
  }

  mrb_value game_obj;
  // Record the detected maker for the crash report before the runtime is built
  // (see the same dispatch in rpg_start_game above).
  if (!FLAGS_script.empty()) {
    std::ifstream ifs(FLAGS_script);
    CHECK(ifs) << "file open failed: " << FLAGS_script;
    std::string str((std::istreambuf_iterator<char>(ifs)),
                    (std::istreambuf_iterator<char>()));
    mrb_const_set(M, mrb_obj_value(M->object_class), mrb_intern_lit(M, "ARGV"),
                  args);
    mrb_gv_set(M, mrb_intern_lit(M, "$0"), mrb_str_new_cstr(M, argv[0]));
    mrb_load_string(M, str.c_str());
    CHECK_NO_EXC(M);
    return EXIT_SUCCESS;
  } else if (fs::exists(game_dir_path / "RPG_RT.ldb")) {
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
  // backtrace plus an ng-log abort. A SystemExit is the exception: the player
  // chose Shutdown, so the process ends with the status `exit` was given.
  if (M->exc) {
    int status = EXIT_SUCCESS;
    if (pending_exit(M, &status)) {
      M->exc = nullptr;
      rgss_tts_shutdown();
      rgss_audio_shutdown();
      gflags::ShutDownCommandLineFlags();
      return status;
    }
    error_dump_report(M, "the running game");
    rgss_tts_shutdown();
    rgss_audio_shutdown();
    gflags::ShutDownCommandLineFlags();
    return EXIT_FAILURE;
  }

  rgss_tts_shutdown();
  rgss_audio_shutdown();
  gflags::ShutDownCommandLineFlags();

  return EXIT_SUCCESS;
#endif
}
