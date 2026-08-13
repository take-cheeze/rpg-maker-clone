- **Enter Hero Name** now fills the screen behind its widget with the same
  full-screen windowskin backdrop `Scene::Menu` and its Item/Skill/Equip/
  Status sub-screens use (`Scene::Base#build_field_background`), instead of
  leaving the frozen map (or nothing at all) showing through the gaps
  between the face box, name-so-far field and character grid. Covers both
  the Latin/digit grid and the hiragana/katakana grid. Covered by new checks
  in `scripts/rpg2k_scene_check.rb` asserting the backdrop sprite is drawn
  full-screen on both paths, and that the name-so-far field renders the
  seeded characters with underscores past them.
