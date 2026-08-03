- **Message Options** (10120) and **Change Face Graphic** (10130) event commands
  are now handled — the top-priority gap in `docs/rpg2000-sample-analysis.md`
  (both appear in real RPG2000 sample games). A saved `Game::MessageConfig` on
  `Game::State` holds the message window's transparency, display position
  (top / middle / bottom), continue-events flag and the FaceSet graphic
  (name / cell index / side / mirror), and `Scene::Map` positions the window,
  draws it transparent when asked and blits the selected 48×48 face cell beside
  the text (inset for a left face, right-aligned for a right face). A new
  `Window#transparent=` draws a frameless message window. Covered by new checks
  in `scripts/rpg2k_logic_check.rb` and `scripts/rpg2k_scene_check.rb`.
