- **RPG2003 gauge battles:** An ally's active-time (ATB) gauge now carries
  into the next fight instead of always restarting from empty — a survivor
  keeps the charge it had when the last battle ended, and only a knockout
  resets it to 0, matching RPG_RT's own between-battle reset logic, ported
  from a reference implementation, not independently confirmed against
  genuine RPG_RT under wine, which deliberately does not reset the gauge
  between fights (only `AddState`'s
  own Knockout branch zeroes it). Previously every actor's gauge silently
  reset to 0 at the start of every encounter, since nothing on the party's
  own actor persisted it between battles the way HP/SP/states/row already
  do. No effect on RPG2000/alternate-layout battles, where the gauge is
  never used. Covered by two new `scripts/rpg2k_logic_check.rb` checks.
