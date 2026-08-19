- **`--rpg2k_map_editor`, `--rpg2k_chipset_editor` and
  `--rpg2k_preview_animation=<id>` open the F9 debug menu's Map Editor,
  Chipset editor and Animation preview straight from the command line.**
  Each starts New Game (like `--rpg2k_new_game`) and immediately pushes the
  corresponding debug tool on top of the map, skipping opening F9 and
  paging to it by hand — combine with `--rpg2k_preview_map` to pick the map
  and with the terminal backends and `--timeout_ms` for a headless
  screenshot of any of them. `RPG2k#open_map_editor`/`#open_chipset_editor`
  push `Scene::MapViewer`/`Scene::ChipsetEditor` the same way the F9 menu
  does; `#fire_preview_animation` drives the field map's animation player
  directly via `#anim_target`/`#build_animation`, the same path a battle
  round uses. `Scene::MapViewer.new` gained a `start_mode:` parameter so the
  flag can land directly in Edit mode instead of the usual pan-mode
  landing page. `Scene::Title#auto_select?`/`#auto_new_game?` were extended
  the same way `--rpg2k_preview_map`/`--rpg2k_battle_troop` already are.
