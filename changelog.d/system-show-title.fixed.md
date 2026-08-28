- **A project with "Show title screen" unchecked now actually skips the
  title screen.** `System#show_title` (LDB chunk 22 field 111,
  `mruby-lcf/mrblib/schema.rb`) has been decoded since the field was named,
  defaulting `true`, but nothing ever read it: `RPG2k#initialize`
  (`mruby-rpg2k/mrblib/main.rb`) always pushed `Scene::Title` unconditionally
  regardless of the flag -- the same "declared but never wired" shape cycle
  #165 found and fixed for Change Battle Background's own save field. A
  project that unchecks this System-tab box (used to open on a scripted
  intro rather than a title menu) got the ordinary title screen -- picture,
  title BGM, New Game/Continue/Shutdown menu -- every time regardless. New
  `RPG2k#show_title?` reads the field (defaulting `true` via `respond_to?`
  guards so a database missing the field, or the whole System table, is
  unaffected); `#boot_title_or_new_game` replaces the old unconditional
  `push Scene::Title.new self` and, when the flag is off, calls
  `#start_new_game` directly instead -- skipping Scene::Title's own asset
  loads entirely (no title picture read, no title BGM ever started only to
  be immediately faded), not merely auto-selecting New Game from a title
  that briefly existed. A data problem in `#start_new_game` (which already
  rescues and logs rather than raising) still falls back to an ordinary
  title screen, so a bad map/database never leaves `@scenes` empty against
  `#main_loop`'s unconditional `@scenes.last.update`. `#return_to_title` and
  `#show_game_over` are untouched: the setting is understood to gate only
  the initial boot, not the in-game "To Title" command or a Game Over's own
  return path, which still need a real Continue/Shutdown menu reachable.
  NOT independently confirmed against genuine RPG_RT under wine this cycle
  (no wine session run) -- implemented from the field's own well-documented,
  unambiguous editor semantics, the same standard this project already
  applies to every other database flag no wine capture has directly probed.
  Covered by four new `scripts/rpg2k_scene_check.rb` checks (`#show_title?`'s
  own defaulting; the skip-title path calling `#start_new_game` with the
  title never pushed; the normal on-path behaving exactly as before; the
  data-problem fallback), confirmed to fail against the pre-fix code before
  the fix.
