- **The window is named after the game that is running.** It used to open as
  LVGL's own "LVGL Simulator" and stay that way, so nothing on screen said which
  project was loaded — and a browser tab said even less. Every maker's boot now
  sets the title from where that maker keeps it: RPG2000/2003 from `RPG_RT.ini`'s
  `GameTitle` (decoded from CP932, as the rest of a 2000/2003 project is), XP
  from `Game.ini`'s `Title`, VX / VX Ace from the database's `System#game_title`,
  and MV / MZ from their own `Scene_Boot`, whose `document.title` assignment now
  reaches the window instead of a stub that dropped it. A project with no title
  of its own falls back to its folder name, and before any game is loaded the
  window says "RPG Maker Clone". Under Emscripten the same call names the
  browser tab; the terminal backends (`--sixel` / `--iterm`) have no window to
  name and are unaffected.
- `RGSS.window_title` is the runtime's own half of it (`RGSS.window_title = ...`
  from Ruby, `window_title_set` natively — see `include/terminal.hxx`), so a
  game can rename the window while it runs, the way an MV plugin retitles the
  page. Covered by new checks in `mruby-rgss/test/test.rb`,
  `scripts/rpg2k_scene_check.rb` and `scripts/rpgvx_testbed_check.rb`.
