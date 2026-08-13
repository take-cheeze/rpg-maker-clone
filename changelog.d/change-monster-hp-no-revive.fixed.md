- **Change Monster HP (13110) can no longer revive a downed (0 HP)
  enemy.** `Game::Interpreter#do_change_monster_hp` applied its delta
  straight to the `Game::Battle::Combatant`, so a positive amount on an
  already-dead troop member (`Combatant#dead?` is `hp <= 0`)
  unconditionally raised its HP back above 0. A positive amount on an
  already-dead target is now a no-op, mirroring the guard
  `Game::Actor#change_hp` already has on the field/actor side
  (`return @hp if dead?`); a further (negative) hit on a dead enemy is
  unaffected and still re-clamps to the command's own lethal-flag floor.
  Covered by a new `scripts/rpg2k_logic_check.rb` check, confirmed to
  fail against the pre-fix code before the fix.
