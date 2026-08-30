- **A map's Show Battle Animation drawing under the picture layer, and
  characters always drawing below every picture, are confirmed already
  correct** — closing two long-standing "still open" z-order questions,
  checked against a reference implementation's source rather than guessed
  at, though not independently confirmed against genuine RPG_RT under wine.
  That reference's drawable-priority ordering ranks the old picture layer
  above the battle-animation layer, and its picture sprites are seeded there
  unconditionally — the lower, animation-above-pictures ordering only
  applies when a version check detects the "RPG2000
  Value!" English re-release or a specifically patched RPG2003 runtime, a
  file/version signal this project has no way to observe from a plain
  `.ldb`/`.lmt`/`.lmu` triple and no test-bed game exercises. This runtime's
  `Scene::Map#setup_sprites` already places `@animation_sprite` (z 150)
  below `@picture_sprite` (z 250), and `@player_sprite` already sorts
  beneath the picture layer through the same existing z-order check.
  Pinned by name, not just transitively, with a new direct assertion added
  to the existing `scripts/rpg2k_scene_check.rb` map-layer-order check.
