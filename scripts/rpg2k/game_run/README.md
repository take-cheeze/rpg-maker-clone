# Headless game runs

`run.sh` runs the real RPG2000 runtime headless on a project: a New Game, or a map and menu, with
the engine's own frame loop (`RPG2k#main_loop`). It links a closed-world mruby build, so the compiled
gems run as bc2cpp generated them, and with `BC2CPP_TRACE_TYPES=1` at build time the run writes a
type dump for `scripts/bc2cpp/trace_types.rb report`.

## Run it

1. Build the closed world (with `BC2CPP_TRACE_TYPES=1` to trace it, `BC2CPP_HOT_ONLY=0` to compile every method):
   `scripts/bc2cpp/closed_build.bash BUILD_DIR`
2. Get a project. `scripts/download/nepheshel.bash` downloads and extracts with `unar`. If `unar` is
   missing, extract with `unzip -O cp932` (the archive's filenames are Shift-JIS).
3. Run:
   `scripts/rpg2k/game_run/run.sh BUILD_DIR/closed /abs/path/to/project new_game [TRACE_OUT]`
   with `workload` = `new_game` or `map_menu`.

## What is real and what is a stub

- The game logic, the interpreter, the maps, and the menus are the engine's own code.
- `stubs.c` replaces the LVGL display symbols the closed library references, because the headless
  run has no display. Every stub returns zero, except that object constructors return a placeholder
  handle and `lv_color_format_get_size` returns the real bytes per pixel. Rendering is not exercised:
  anything that reads a screen size or a drawn result sees zero.
- `gamedriver.cpp` passes a placeholder display to `rgss_set_display`, and `run.sh` sets `RTP_DIR` to
  an empty string, since the project has no RTP.
- The workloads run a fixed number of frames with no input. They do not cover battles, shops, or saves.

## Regenerating the stubs

`stubs.c` lists the LVGL symbols the link needs. If the closed build changes and the link reports new
`lv_*` symbols, add them as `long NAME(void) { return 0; }`, or as a placeholder for an object constructor.
