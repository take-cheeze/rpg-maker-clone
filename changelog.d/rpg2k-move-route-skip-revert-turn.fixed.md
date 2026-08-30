- **A blocked Move Route step on a skippable ("Ignore If Can't Move") route
  no longer leaves the character visibly turned toward the obstruction —
  the failed turn now reverts entirely before the route advances.**
  Ported from a reference implementation, not independently confirmed
  against genuine RPG_RT under wine: a skippable route's failed
  move reverts both direction and facing to what they were before the
  attempt, so a skipped step has no visible effect at all. This engine
  turned the character to face the obstacle unconditionally and never
  reverted it, so a skippable route's character stayed turned toward every
  obstacle it brushed past, even ones it visibly walked around.
