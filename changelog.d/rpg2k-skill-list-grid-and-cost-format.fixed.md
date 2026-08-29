- **The Skill screen's list is now a two-column grid with the correct SP
  cost format, matching genuine RPG_RT.** Ported from a reference
  implementation (`column_max = 2`, cost drawn as
  `"{separator}{cost:3d}"` with no MP/SP unit suffix, default separator a
  hyphen), not independently confirmed after this session's wine reference
  runtime stopped rendering past Continue. `Scene::SkillMenu` also no longer
  lets LEFT/RIGHT switch the caster inside the screen -- again ported from a
  reference implementation, which has no such mechanism (unlike its equip
  screen, which does, and was left unchanged) -- freeing LEFT/RIGHT for the
  grid's column navigation, and likewise not independently confirmed against
  genuine RPG_RT under wine.
