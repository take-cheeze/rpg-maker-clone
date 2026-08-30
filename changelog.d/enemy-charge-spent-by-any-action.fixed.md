- **An enemy's Charge bonus is now spent by whatever it does next, not only
  by its own next Attack.** Ported from a reference implementation, not
  independently confirmed against genuine RPG_RT under wine, whose own
  action-start step clears the
  charge unconditionally for every action kind (skill, defend, observe,
  transform, self-destruct, everything), so a charge previously survived
  untouched through any number of non-attack turns and still doubled a much
  later attack. Also fixed: both swings of a charged dual attack now double
  (that same reference models it as one action with a repeat count of 2, not
  two independent attacks), where only the first used to.
