- **Enter Hero Name (10740) now draws RPG_RT's own screen.** Compared frame by
  frame against genuine RPG_RT.exe under wine on Nepheshel's New Game name
  prompt, the kana widget was laid out to its own geometry: the three windows
  now sit where RPG_RT puts them (a 64x64 face window at (32, 8), a 192x32 name
  field at (96, 40) and the 256x160 gojuuon grid at (32, 72)), the grid's
  columns are 24px apart with the voiced/small-kana half pushed 6px further,
  its cursor hugs the cell's text (12px on a kana, 36px on the labels), the
  toggle/confirm cells read `<かな>`/`<カナ>`/`<決定>` in half-width brackets,
  the name field centres its twelve half-width slots with a half-width
  underscore in each empty one and a 12x16 cursor on the slot after the last
  character (past the sixth slot once the name is full), and every string goes
  through the windowskin's colour gradient and shadow instead of flat white.
  The name field, which the native build had been drawing empty, shows its
  seeded name again: the game's mruby counts string bytes, not characters, so
  a two-kana seed read as six lone bytes -- the widget now splits names into
  codepoints (`Scene::Base#utf8_chars`) for its slots, its six-kana limit and
  backspace. Two behaviours were measured too: the keystroke that
  fills the sixth slot parks the grid cursor on `<決定>` so the next Decision
  confirms, and the two-column label cells are stepped over as one cell
  (Left from `<決定>` lands on `<かな>`, a vertical move onto a label's second
  column snaps to the label). The field-menu backdrop shared by the main menu
  and its sub-screens is now a solid fill of the System image's (0, 32) pixel,
  which is what RPG_RT paints behind every menu, rather than the window's
  32x32 background chip stretched over the screen. Covered by new and updated
  checks in `scripts/rpg2k_scene_check.rb`.
