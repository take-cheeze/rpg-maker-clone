- The **`command_actor` battle-page condition now fires in a gauge battle**,
  closing the "never satisfiable" gap that the ADR 0054 turn-cycle work left
  open. The battle tracks the acting battler (`Game::Battle#acting_battler`,
  set as each turn resolves), the per-battler boundary page check passes it as
  the `source` the way EasyRPG's `ScheduleNextPage(flags, source)` does, and
  `Game::Battle#actor_command` answers that battler's recorded command
  (`Combatant#last_battle_action`) — so the page fires for the battler who
  actually chose the command, and only its own. The same source gates the
  `turn_enemy` / `turn_actor` conditions (a per-battler check never fires off
  a different battler's counter), while a no-source round-boundary check stays
  ungated and a turn-based (RPG2000) battle leaves `command_actor` unmet,
  matching real RPG_RT. Covered by new `rpg2k_logic_check.rb` checks
  (satisfiable at the acting battler's turn, wrong-source/different-battler
  failures, turn_enemy/turn_actor source gating) and a `rpg2k_scene_check.rb`
  check driving a real gauge battle whose `command_actor` troop page fires.
