- **A map event's Control Variables map id (operand 6, attribute 0) now
  reads the real map id on an RPG2003 database, instead of RPG_RT's RPG2000
  bug applying to every game regardless of edition.** A reference
  implementation's own Control Variables event-operand code (ported from
  that source, not independently confirmed against genuine RPG_RT under
  wine)
  is explicit that always reading 0 for a map event's map id is "an RPG_RT bug
  for 2k only" — it only reads 0 for an RPG2000 map event that isn't the
  hero or a vehicle; RPG2003, or the hero/vehicle characters, take the
  real-map-id branch instead, so a genuine RPG2003 project
  takes the *true* branch and reads the event's real (current) map id, just
  like the hero and vehicle branches beside it. `Game::Interpreter#event_operand`
  zeroed that case unconditionally, with no edition check at all. Fixed with a
  new `Game::Party#rpg2003?` (mirroring `#db_item`/`#db_skill`'s own `@db`
  reach-through) consulted by that one branch: RPG2000 still reads 0, RPG2003
  reads `@state.map_id`. Covered by a new `scripts/rpg2k_logic_check.rb`
  check, confirmed to fail against the pre-fix code before the fix.
