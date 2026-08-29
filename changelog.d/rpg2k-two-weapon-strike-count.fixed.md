- **A 二刀流 (dual-wielding) actor with a weapon in both hands now swings at
  least twice per basic Attack, even when neither individual weapon is
  itself flagged "attacks twice."** Ported from a reference implementation,
  not independently confirmed against genuine RPG_RT under wine: it sums
  each weapon's own hit count once both hands hold a real weapon, a
  different rule from the
  ordinary single-weapon case. This engine only ever checked whether either
  equipped weapon carried its own "attacks twice" flag, so a two-weapon
  actor built from two ordinary weapons — the common case — attacked only
  once a round, the same as an unarmed actor.
