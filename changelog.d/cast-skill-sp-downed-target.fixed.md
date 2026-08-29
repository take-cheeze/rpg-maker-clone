- **Field Skill menu:** a skill with Affect SP on but no Death cure no
  longer restores SP on a downed (dead, non-revived) party member -- matching
  RPG_RT's own skill-use logic, ported from a reference implementation, not
  independently confirmed against genuine RPG_RT under wine, whose
  SP-restoration branch carries the identical `!IsDead()` guard its HP
  sibling already had. Previously a
  KO'd member's SP could be silently topped up while they stayed downed.
