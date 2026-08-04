- The battle screen now takes **per-actor commands each round** instead of a
  single party-level Fight. For every living party member the player picks
  **Attack** (then chooses which enemy to target) or **Defend**, and the round
  then executes — party actions and enemy attacks resolve in agility order —
  repeating until one side falls. Defending halves the damage that member takes
  that round and forgoes its attack; cancelling on the first actor flees when the
  encounter allows escape. `Game::Battle` gained the round-based API this needs
  (`command_attack` / `command_defend` / `run_round`, with a chosen target and
  the defend halving) alongside the existing headless `run`. The per-turn
  animation, and Skill / Item commands, are still to come. Covered by new checks
  in `scripts/rpg2k_logic_check.rb` (commanded-target attack, defend halves
  damage) and updated ones in `scripts/rpg2k_scene_check.rb` (Attack to a win /
  a loss over multiple rounds, and Flee).
