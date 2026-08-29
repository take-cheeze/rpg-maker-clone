- **The per-actor battle command menu now matches RPG_RT's own order and
  honours an actor's Skill-command rename**, instead of assuming Attack /
  Skill / Item / Defend and a fixed "Skill" label for everyone.
  `Scene::Map#battle_commands` built its four labels (and `#select_battle_command`
  routed its cursor rows) as Attack / Skill / Item / Defend; a reference
  implementation's own battle-command-window builder (ported from that
  source, not independently confirmed against genuine RPG_RT under wine)
  orders the four commands with Defend
  ahead of Item — so every battle menu had two commands swapped, and pressing
  the confirm key on the third row committed Item's sub-menu instead of the
  one-shot Defend RPG_RT puts there. Fixed by reordering the array and the
  `select_battle_command` case labels to match. Separately, RPG2000's Actor
  sheet has a "custom battle command" checkbox + name field (database fields
  66/67, `custom_battle_command` / `custom_battle_command_name`) that renames
  just the Skill slot per actor — parsed by the schema and never read
  anywhere in `mruby-rpg2k` before now, so a game that set it (e.g. renaming
  Skill to "Magic") showed the generic term regardless. `Game::Actor
  #rename_skill?` / `#skill_command_name` read the two fields, and
  `Scene::Map#skill_command_label` substitutes the custom name for the
  current actor's turn, mirroring a reference implementation's own
  skill-name lookup (again ported without independent confirmation against
  genuine RPG_RT under wine): the custom name when the rename flag is set,
  the database's own "Skill" term otherwise. Covered by new
  `scripts/rpg2k_scene_check.rb` checks (the drawn label order; cmd row 2
  committing Defend rather than opening the Item list; an actor with the
  rename flag showing its custom name; an actor without it keeping the
  database "Skill" term) and three existing checks that assumed the old
  Item-before-Defend order updated to match, confirmed to fail against the
  pre-fix code before the fix.
