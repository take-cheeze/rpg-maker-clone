- An enemy's **battle-graphic hue shift** (database field 3, `battler_hue`)
  was parsed by the LCF schema but read nowhere in `mruby-rpg2k` — a `ruby
  scripts/rpg2k_field_audit.rb` run against a freshly re-downloaded
  Nepheshel and mtf-meido-action flagged it (3 rows, Nepheshel only). A game
  reusing one `Monster/<name>` bitmap for several palette-swapped monsters
  (a red slime and a blue slime sharing "Slime.png", a common RPG2000
  authoring trick that avoids shipping a separate file per colour) always
  drew every one of them in the file's own unshifted colour. Verified
  against EasyRPG Player's actual C++ source rather than guessed at:
  `Game_Enemy::GetHue` (`src/game_enemy.h`) is a bare `enemy->battler_hue`
  passthrough, and `Sprite_Enemy::OnMonsterSpriteReady`/`Refresh`
  (`src/sprite_enemy.cpp`) rotate the decoded bitmap through
  `Bitmap::HueChangeBlit` whenever it is nonzero, rebuilding the sprite
  whenever either the graphic name or the hue changes. Ported as
  `Game::Enemy#battler_hue` (read the same way `levitate`/`transparent`
  already are) and a new `Combatant#battler_hue` field, fed into
  `Scene::Map#battler_bitmap` (`mruby-rpg2k/mrblib/scene/map.rb`), which now
  calls the existing `Bitmap#hue_change` (already used elsewhere in this
  build's RGSS layer) on a freshly decoded battler and keys its
  `@monster_cache` by name **and** hue rather than name alone — `hue_change`
  mutates its bitmap in place, so a same-file, zero-hue enemy sharing the
  cache with a hued one must decode its own copy rather than share the
  rotated one. `#refresh_battle_sprites`/`#rebuild_battler_sprite` and a
  monster Transformation (`Game::Battle#enemy_transform_action`) now track
  and compare hue the same way they already track `battler_name`, matching
  EasyRPG's own `Sprite_Enemy::Refresh` rebuilding on either changing.
  Covered by a new `scripts/rpg2k_scene_check.rb` check (a hue-120 fixture
  enemy's built sprite records exactly one `hue_change(120)` call; a
  same-file zero-hue enemy sharing the scene's cache decodes unrotated; a
  mid-fight transformation back to the zero-hue battler redraws with no
  rotation), confirmed to fail against the pre-fix code (`NoMethodError:
  undefined method 'battler_hue'`) before the fix.
