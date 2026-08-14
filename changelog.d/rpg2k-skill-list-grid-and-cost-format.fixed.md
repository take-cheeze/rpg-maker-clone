- **The Skill screen's list is now a two-column grid with the correct SP
  cost format, matching genuine RPG_RT.** Confirmed via EasyRPG Player's
  own `Window_Skill` source (`column_max = 2`, cost drawn as
  `"{separator}{cost:3d}"` with no MP/SP unit suffix, default separator a
  hyphen) after this session's wine reference runtime stopped rendering
  past Continue. `Scene::SkillMenu` also no longer lets LEFT/RIGHT switch
  the caster inside the screen -- confirmed against EasyRPG's own
  `Scene_Skill`, which has no such mechanism (unlike `Scene_Equip`, which
  does, and was left unchanged) -- freeing LEFT/RIGHT for the grid's column
  navigation.
