- **Actors:** every stat a levelled actor derives from the database's growth
  curve (max HP/SP, ATK/DEF/SPI/AGI, for both an actor's own curve and an
  RPG2003 class's) is now read in the correct byte order, matching RPG_RT --
  the curve's raw shorts are six blocks of one stat across every level, not
  the other way around, and reading it the wrong way silently gave every
  multi-level actor (and any class-changed actor) wrong stats, worse the
  further from level 1 the affected curve stat's growth actually was.
