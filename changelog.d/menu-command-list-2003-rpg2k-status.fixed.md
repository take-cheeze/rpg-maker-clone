- **The field menu now shows the right command list for the editor that wrote
  the game, instead of a fixed six commands.** `Scene::Menu` hardcoded Item,
  Skill, Equip, Status, Save, End Game for every project, but RPG2000's own
  menu is only *five* commands — Item, Skill, Equip, Save, End Game, with **no
  Status entry at all** (EasyRPG's `Scene_Menu::CreateCommandWindow`'s
  `Player::IsRPG2k()` branch hardcodes exactly that set regardless of database
  content; RPG2000's party list already shows name/level/HP/MP, and Equip
  already shows the full stat block, so there is nothing for a separate Status
  screen to add). RPG2003 replaces the fixed list with the System database's
  own customizable one (chunk 22 field 27, `menu_commands` — unread until now)
  matching EasyRPG's `CommandOptionType` enum: Item, Skill, Equipment, Save,
  Status, Row, Order, Wait, with Quit/End Game appended unconditionally after
  it. A real RPG2003 game's array both picks *which* commands show (mtf-
  meido-action's is `[1, 2, 3, 4, 5, 6, 7, 8]`, all eight) and their *order* —
  our own Status command had no way to appear via the customizable list, and a
  game that reordered or dropped a command (hiding Save, say) had that ignored
  entirely. `Scene::Menu#build_commands` now branches on `LCF::Database#rpg2003?`
  (ADR 0013's edition detector): the RPG2000 fixed five, or the RPG2003
  database's own list filtered through a small id→command table. Row (battle
  front/back rank), Order (party reordering) and Wait (the ATB toggle) have no
  entry in that table and are silently skipped — RPG2003 battle-system
  features this runtime does not model, the same reported-gap precedent the
  Toggle ATB Mode (5003) event command already establishes. Covered by new
  `scripts/rpg2k_scene_check.rb` checks (a non-2003 database never offers
  Status; a 2003 database's full eight-command array offers Status and drops
  Row/Order/Wait; a 2003 database that reorders and omits commands is honoured
  end to end, including actually opening the reordered Status screen),
  confirmed to fail against the pre-fix code (Status always offered; a 2003
  reorder/omission ignored) before the fix.
