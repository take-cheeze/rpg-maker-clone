- **`--rpg2k_map_editor`, `--rpg2k_chipset_editor` and
  `--rpg2k_preview_animation=<id>` no longer require `--test_play`/`Game.ini`
  `[Game] Test=1` alongside them.** Every other debug/CI flag this engine
  ships is reset outside test play (`disable_non_test_play_flags` in
  `src/main.cxx`) since a released game should never expose them regardless
  of what's on its command line — but passing one of these three is already
  the same kind of deliberate, explicit opt-in `--test_play` itself would be,
  so the extra flag only meant retyping `--test_play` every time to open an
  editor. The three are now excluded from that reset; interactive F9 access
  to the same tools during ordinary play is untouched, still gated on
  `RPG2k#test_play` in `Scene::Map#try_open_debug_menu` as before.
