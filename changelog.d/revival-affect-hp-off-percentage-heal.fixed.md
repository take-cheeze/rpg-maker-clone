- **RPG2003 skills:** A revival skill whose own "Affect HP" flag is off —
  a common "cure Death, heal a % of max HP" design, distinct from a
  flat-amount reviver — now heals the correct percentage of max HP,
  matching RPG_RT, in both battle and from the field menu. Previously such
  a skill always revived the target to a flat 1 HP, the same as a skill
  with no heal configured at all, ignoring its own Power/rate entirely.
  Covered by new `scripts/rpg2k_logic_check.rb` checks.
