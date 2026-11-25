- **The Wio Terminal firmware leaves out the RPG2k developer tools**: the F9
  debug menu, the map viewer/editor and the chipset editor
  (`Scene::DebugMenu`, `Scene::MapViewer`, `Scene::ChipsetEditor`). F9 and
  `RPG2k#open_map_editor` / `#open_chipset_editor` do nothing there. Every
  other build keeps them; `WIO_DEBUG_SCENES=1` keeps them on wio too.
