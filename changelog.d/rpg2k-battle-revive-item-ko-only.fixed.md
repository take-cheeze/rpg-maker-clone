- **A downed party member can now be targeted with a Battle Item, and a
  revive-only (`ko_only`) item cast in battle actually revives them.**
  Ported from a reference implementation, not independently confirmed
  against genuine RPG_RT under wine: the battle Item ally picker used
  to exclude every KO'd ally outright, so a revive item could never be aimed
  at the person it was meant to save, and the battle code path never checked
  the "does nothing unless the target is down" flag at all, so casting one on
  a living ally silently worked as a free full heal instead.
