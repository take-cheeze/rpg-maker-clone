- **The field menu screens (Menu, Item, Skill, Equip, Status, Save/Load) now
  play RPG2000's four system sound effects, matching genuine RPG_RT.**
  Confirmed via EasyRPG Player's source (`Window_Selectable::Update()` for
  Cursor SE on every successful list/grid move, `Scene_Menu::UpdateCommand`/
  `UpdateActorSelection` for exactly when Decision vs. Buzzer plays):
  cursor movement plays the Cursor SE, confirming a command or list entry
  plays Decision, cancelling back out plays Cancel, and confirming something
  that gets refused outright (an empty party, Save while disabled, Skill on
  a restricted actor, a "no effect" item/skill use) plays Buzzer instead of
  Decision. The shared `play_system_se`/`system_se` lookup (Change System
  SFX override, falling back to the database default) moved from
  `Scene::Map` up to `Scene::Base` so every scene can reach it.
