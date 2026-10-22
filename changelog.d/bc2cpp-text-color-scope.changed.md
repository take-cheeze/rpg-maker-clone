- The bc2cpp type check now types a constant whose bare name is also written
  elsewhere, when a bare read from it cannot reach those other writes.
  `RPG2k::Scene::ChipsetEditor::TEXT_COLOR` and `MapViewer::TEXT_COLOR`
  (`Color.new(...)`) are reported as `RGSS::Color` instead of untyped, because
  `EquipMenu::TEXT_COLOR` and `SaveLoad::TEXT_COLOR` (integer `0`) no longer
  block the whole bare name. The resulting hints are guarded at dispatch.
