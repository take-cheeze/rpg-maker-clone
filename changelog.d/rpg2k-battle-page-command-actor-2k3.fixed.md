- **A troop battle-event page's `command_actor` condition is now correctly
  RPG2003-only, matching its turn_enemy/turn_actor/fatigue siblings.** It
  used to be evaluated on every database, which permanently disabled a page
  using only this condition on an RPG2000 game, where real RPG_RT would
  have run it unconditionally.
