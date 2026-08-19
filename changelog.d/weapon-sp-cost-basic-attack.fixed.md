- **RPG2003 battles:** A basic Attack now spends the equipped weapon's own
  SP cost (消費SP), once per action regardless of dual-wield's extra swing,
  halved by MP消費半分 gear -- matching RPG_RT. Previously a weapon flagged to
  cost SP was effectively free to swing forever. Covered by a new
  `scripts/rpg2k_logic_check.rb` check.
