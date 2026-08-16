- The **RPG2003 battle combo is now spent** — the one Enable Combo (1007)
  arming that was recorded but never acted on. The scene records the battle
  command an actor chooses (`Combatant#last_battle_action`, the fixed four
  mapping to EasyRPG's default ids 1-4, a customized list to its own refs),
  and `Game::Battle#combo_hits` multiplies the hits of that command when an
  armed combo names it exactly — a combo'd basic Attack lands its full combo
  count, a combo'd skill repeats its effect with the SP spent once, and (like
  real RPG_RT/EasyRPG) a Defend / Item / Escape command is never combo'd. The
  combo stays armed for the whole fight, matching EasyRPG's
  `ProcessBattleActionCombo`. Covered by new `rpg2k_logic_check.rb` checks
  (armed/wrong-command/Item cases, single- and all-target skill SP-spent-once)
  and `rpg2k_scene_check.rb` checks pinning the command-id recording.
