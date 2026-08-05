- RPG Maker 2000: **gear can now shield its wearer from critical hits**. Items
  carrying the database `prevent_critical` flag (RPG2000 armor with "prevent
  critical hits") are surfaced through `Game::Actor#prevents_critical?`, which
  scans the actor's equipped items, and the result is snapshotted onto the
  `Combatant` (`prevents_crit`). In `deal_attack` the critical roll is now gated
  on the target: a battler protected by prevent-critical gear can never be crit,
  so the attack lands for its ordinary damage even when the attacker's chance
  rolls a hit. Matches EasyRPG's `Game_Battler::PreventsCritical`. Covered by new
  `scripts/rpg2k_logic_check.rb` checks (prevent-critical gear blocks the 3x hit;
  `Game::Actor#prevents_critical?` reads the equipped flag).
