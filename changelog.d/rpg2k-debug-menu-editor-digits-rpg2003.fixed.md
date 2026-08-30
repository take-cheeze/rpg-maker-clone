- **The F9 debug menu's variable-value editor now widens to 7 digits on an
  RPG2003 database**, instead of staying a flat 6 digits on every database.
  Ported from a reference implementation, not independently confirmed
  against genuine RPG_RT under wine: RPG2003 widens the editable range 10x,
  mirroring the same edition split
  this engine already applies to the underlying variable range itself. A
  flat 6-digit editor could not enter or even display an RPG2003 variable's
  own top decade.
