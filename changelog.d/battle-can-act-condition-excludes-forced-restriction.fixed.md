- **A battle event's "Actor: Can Fight" Conditional Branch condition now
  fails for a Berserk or Confused actor**, reversing a prior assumption
  that such an actor "still acts" and should pass. Confirmed by an actual
  wine A/B against genuine RPG_RT.exe: a synthetic troop battle-event page
  read `CANACT_YES` for a Normal leader and `CANACT_NO` for the identical
  leader afflicted with Berserk. `Interpreter#battle_actor_condition`/
  `#battle_enemy_condition` (`mruby-rpg2k/mrblib/interpreter.rb`) now
  delegate to `Game::Battle#command_restricted?` instead of the narrower
  `#do_nothing_restricted?`, so a forced attack-enemy/attack-ally
  restriction fails the check the same way a "do nothing"
  (asleep/paralysed) restriction already did.
