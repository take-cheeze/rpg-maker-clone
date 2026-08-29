- **The field Skill screen now shows the highlighted skill's flavour text in
  a one-line banner across the top**, the same banner `Scene::ItemMenu` and
  `Scene::EquipMenu` already have. Ported from a reference implementation,
  not independently confirmed against genuine RPG_RT under wine: that
  reference implementation feeds the database skill's own `description`
  field straight to its skill screen's help banner on every selection
  change. `Scene::SkillMenu` drew no
  such banner before — `skill.description` was parsed by the LCF schema and
  never read anywhere in `mruby-rpg2k`, a gap `scripts/rpg2k_field_audit.rb`
  surfaced against a real game's database (127 skills setting the field).
  The banner tracks the cursor in the skill list and keeps showing the
  pending skill's own text while picking a target or a teleport destination.
