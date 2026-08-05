- RPG Maker 2000: battle skills can now target **all enemies (scope 1)** or **all
  allies (scope 4)**. `Game::Battle#command_skill_all` queues a volley — a list of
  per-target `{ target, hp, mp }` effects (attack damage still varies with each
  target's defence) — and `apply_command` spends the caster's SP once, then
  applies the shared effect / infliction to every living target, producing one
  log entry per hit. A new pending-hit buffer lets `#step` / `#step_action`
  surface those hits one at a time, so the battle screen animates the volley
  target by target; a volley skips foes already down and fizzles (no SP spent)
  when every target has fallen. The battle menu now offers all-target skills
  (`BATTLE_SKILL_SCOPES` gained 1 and 4) and casts them without a target prompt.
  Covered by new `scripts/rpg2k_logic_check.rb` checks (an all-enemy volley hits
  every foe for one SP charge, an all-ally heal restores each member, downed
  targets are skipped, an all-dead volley fizzles, and `run_round` surfaces every
  hit). All-target *items* remain a follow-up.
