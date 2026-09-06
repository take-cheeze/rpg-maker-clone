- **The RPG2000 field Skill screen (`Scene::SkillMenu`) now matches genuine
  `RPG_RT.exe` (measured under wine, cycle #241).** It draws RPG_RT's three
  stacked full-width windows -- the description banner, a separate one-line
  caster status window ("デモ用   LV50   正常   HP600/600   MP600/600": terms
  in system colour 1, the level in a 2-cell field, HP/MP as `%3d/%3d` pairs,
  only the current figure recoloured when critical) and a skill grid box that
  always runs to the bottom of the screen -- instead of a content-sized box
  with a "name   MP cur/max" header. The grid's column pitch is 160px with a
  144x16 cell cursor, the SP cost is `-%3d` right-aligned to contents x 144 of
  the cell, lists longer than ten rows scroll one row at a time with the
  cursor pinned to the bottom/top visible row and blinking down/up arrows,
  and every known skill is listed in the actor's own order -- enemy-scope
  attacks, stat buffs, battle-only-state cures and battle-only switch skills
  included, greyed rather than hidden (`Game::Party#field_skills` no longer
  filters or re-sorts; `#field_skill?` is the greying check). The target
  window's rows use the same `LV%2d` / `%3d/%3d` cells and its row cursor
  starts at the label column. Covered by new `scripts/rpg2k_scene_check.rb`
  checks and updated `scripts/rpg2k_logic_check.rb` expectations.
