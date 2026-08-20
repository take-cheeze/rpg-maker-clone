- **Battle:** An enemy action-pattern entry with an out-of-range condition
  type now fires unconditionally instead of being permanently excluded --
  matching RPG_RT's own `EnemyAi::IsActionValid`, whose `default` case
  returns eligible, not ineligible.
