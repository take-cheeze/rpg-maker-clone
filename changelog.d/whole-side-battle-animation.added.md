- **Battle-page Show Battle Animation (13260)** now supports `target -1`, the
  "whole side" sentinel EasyRPG's `Game_Interpreter_Battle::
  CommandShowBattleAnimation` uses: one animation plays over every living troop
  member at once instead of a single index. The animation player
  (`Scene::Map#build_animation`) was generalised from a single `target_index`
  to a `targets` array, so `#draw_map_animation` blits each frame over every
  target and `#fire_animation_flashes` / `#hold_animation_target_flash` flash
  and clear every target's sprite. An ally-flagged whole side collapses to the
  single screen-centre fallback (RPG2000's front view draws no ally sprite).
  Covered by two new checks in `scripts/rpg2k_scene_check.rb`.
