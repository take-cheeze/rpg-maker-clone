- **RPG2003's per-actor battle-command customization now drives the in-battle
  menu.** An acting actor whose own `Game::Actor#battle_commands` (edited by
  Change Battle Commands (1009) or a class change) resolves to at least one
  usable entry now sees that list — in its own order, reordered or shortened —
  instead of always the fixed Attack/Skill/Defend/Item four, and
  `Scene::Map#select_battle_command` dispatches by each row's own action
  rather than a fixed index, so a customized list still routes to the right
  handler. Resolving a positive id reads a new LCF chunk 29 (the database-wide
  Battle Commands table, `mruby-lcf/mrblib/schema.rb`) via a new
  `Game::Actor#battle_command_row`; a database without it (every RPG2000 file)
  or a list with nothing usable in it falls back to the fixed four as before.
