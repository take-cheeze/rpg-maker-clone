- The on-screen battle now **plays each round out action by action** instead of
  applying it all at once. Once every party member is commanded, the round
  animates one attack per `BATTLE_ANIM_FRAMES` (~1/3s at 60fps): each hit lands
  in agility order, ticking the target's HP down in the status panel and
  bannering the blow (`Hero hits Slime for 12`, `… defeated!`) low on the screen,
  before the next lands — so the HP drains turn by turn rather than jumping to
  the round's end state. When the round's queue empties the commands clear and
  the screen re-opens the command menu, or shows the result once a side falls.
  `Game::Battle` gained the round-stepping API this animates on — `#begin_round`
  primes the agility-ordered queue, `#step_action` surfaces one landed attack at
  a time (skipping the dead and defenders) and returns nil at the round boundary
  without starting a new round, and `#end_round` clears the commands; `#run_round`
  is now just that sequence run to completion, so its contract is unchanged.
  Skill / Item commands, battler sprites and game over on defeat are still to
  come. Covered by new checks in `scripts/rpg2k_logic_check.rb` (a round steps
  one attack at a time, a defender is skipped) and `scripts/rpg2k_scene_check.rb`
  (the round animates action by action rather than at once).
