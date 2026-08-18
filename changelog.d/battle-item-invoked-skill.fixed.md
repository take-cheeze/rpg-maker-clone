- **Battle scene:** a special/`use_skill` item invoking an enemy- or
  all-enemy-scope attack skill (Nepheshel's thrown-bomb line among them) is
  now actually usable from the in-fight Item menu — it used to be offered
  there, prompt for an *ally*, and silently do nothing, since the confirm
  handler always ran the plain medicine math instead of casting the item's
  invoked skill. `#drive_battle_item` now dispatches on the skill's own
  scope the same way the Skill menu already does, the item pays instead of
  the caster's own SP, and the cast is correctly exempt from Reflect Magic,
  matching a caster's own item-backed cast in the real engine. Covered by a
  new `scripts/rpg2k_scene_check.rb` check.
