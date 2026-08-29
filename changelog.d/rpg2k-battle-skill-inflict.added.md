- RPG Maker 2000: **battle attack skills now inflict status conditions**. An
  enemy-scope skill's `state_effects` (index `i` → state id `i+1`) ride along on
  its battle command (`battle_skill_command`), and `apply_command` rolls each
  against the skill's **`hit` accuracy** (default 100) on a target that survives
  the hit — adding the state to the target combatant. So a Poison Sting or Sleep
  spell afflicts the foe, which then slips HP or skips its turn through the
  per-turn state processing added alongside. `command_skill` threads the inflict
  set and chance through, and `Scene::Map` passes them from the skill menu. The
  chance is grounded on a reference implementation's to-hit for skill
  states, not independently confirmed against genuine RPG_RT under wine;
  a defeated target is
  not afflicted, and a state the target already carries is not re-rolled. Covered
  by new `scripts/rpg2k_logic_check.rb` checks (a 100%-accuracy skill inflicts its
  state on a surviving enemy, a 0%-accuracy skill never does, and an inflicted
  "do nothing" state then skips the enemy's next turn). Enemy-cast infliction,
  state auto-recovery, and forced-attack restrictions remain follow-ups.
