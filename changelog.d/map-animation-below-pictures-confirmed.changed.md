- **A map's Show Battle Animation drawing under the picture layer, and
  characters always drawing below every picture, are confirmed already
  correct** — closing two long-standing "still open" z-order questions,
  verified against EasyRPG Player's actual C++ source rather than guessed
  at. `Drawable::Priority` (`src/drawable.h`) orders `Priority_PictureOld`
  (120) above `Priority_BattleAnimation` (110), and `Sprite_Picture`'s
  constructor (`src/sprite_picture.cpp`) seeds every picture there
  unconditionally — the lower, animation-above-pictures ordering only
  applies when `Player::IsMajorUpdatedVersion()` detects the "RPG2000
  Value!" English re-release or a specifically patched RPG2003 runtime, a
  file/version signal this project has no way to observe from a plain
  `.ldb`/`.lmt`/`.lmu` triple and no test-bed game exercises. This runtime's
  `Scene::Map#setup_sprites` already places `@animation_sprite` (z 150)
  below `@picture_sprite` (z 250), and `@player_sprite` already sorts
  beneath the picture layer through the same existing z-order check.
  Pinned by name, not just transitively, with a new direct assertion added
  to the existing `scripts/rpg2k_scene_check.rb` map-layer-order check.
