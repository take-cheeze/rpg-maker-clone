- **A troop battle-event page's turn_enemy/turn_actor/fatigue conditions are
  now correctly RPG2003-only.** They used to be evaluated on any database,
  which could make a page conditional (and potentially never fire) when
  real RPG_RT would have run it unconditionally, since the RPG2000 editor
  has no controls for these condition types at all.
