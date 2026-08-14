- **A skill's ATK/DEF/SPI/AGI stat change and attribute-defence shift now
  announce themselves in battle**, instead of moving the target's numbers
  silently. `Game::Battle#apply_stat_mods`/`#apply_attr_shift`
  (`mruby-rpg2k/mrblib/game.rb`) already computed the effect and threaded it
  onto every battle log entry as `stat_changed`/`attr_shifted`, but nothing
  ever read either key back into a message — database `term` chunk fields
  30/31/34/35 (`parameter_increase`/`parameter_decrease`/
  `resistance_increase`/`resistance_decrease`) were parsed but named nowhere
  in `mruby-rpg2k`. EasyRPG Player's actual C++ source confirms this is
  RPG2000's own battle scene, not an RPG2003-only path:
  `scene_battle_rpg2k.cpp`'s `ProcessBattleActionStateEffects`/
  `ProcessBattleActionAttributeEffects` push a message from
  `BattleMessage::GetAtkChangeMessage`/`GetDefChangeMessage`/
  `GetSpiChangeMessage`/`GetAgiChangeMessage` and `GetAttributeShiftMessage`
  (`game_message_terms.cpp`) for every landed action. Ported as
  `Game::States::BattleText.parameter_change`/`.attribute_shift`, wired into
  `Scene::Map#battle_state_lines` (`mruby-rpg2k/mrblib/scene/map.rb`)
  alongside the existing inflicted/cured/defeated sentences — one line per
  ATK/DEF/SPI/AGI key that actually moved, and one per attribute id whose
  resistance rank shifted, each falling back to composed English when the
  database leaves the term blank. `Game::Battle#apply_skill_hit` now also
  threads `attr_shift_dir` (the shift's own +1/-1) onto the log entry, since
  `apply_attr_shift` previously reduced it to a bare list of moved attribute
  ids with no direction to report. Covered by five new
  `scripts/rpg2k_scene_check.rb` checks, confirmed to fail against the
  pre-fix code before the fix.
