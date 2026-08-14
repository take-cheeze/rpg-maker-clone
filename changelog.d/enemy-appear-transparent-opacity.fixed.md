- **An enemy flagged "Appear Transparent" now draws its battle sprite at
  reduced opacity for the whole fight.** The monster schema's `transparent`
  field (LCF enemy field 10) was parsed but read nowhere in `mruby-rpg2k`,
  the same "parsed but unused" gap `levitate` had before its own fix, so
  every enemy always drew fully opaque regardless of the flag. Confirmed
  against EasyRPG Player's C++ source (`Game_Enemy::IsTransparent`/
  `Sprite_Enemy::Draw`): flagged, it draws at 160/255 (~63%) opacity, purely
  cosmetic with no accuracy/evasion effect. Implemented with a new
  `Game::Enemy#transparent` reader and `Scene::Map#battler_opacity`, wired
  into every site that (re)builds an enemy sprite — the initial build, a
  mid-fight transformation redraw, and Show Hidden Monster. Covered by new
  `scripts/rpg2k_logic_check.rb` and `scripts/rpg2k_scene_check.rb` checks,
  confirmed to fail against the pre-fix code before the fix.
