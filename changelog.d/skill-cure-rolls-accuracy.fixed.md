- **RPG2003 battles:** A curative battle skill's status cure (e.g. curing
  Poison or Silence) now rolls its own accuracy chance, matching RPG_RT.
  Previously the cure landed unconditionally, so a skill whose configured
  `hit` rate was below 100% still always cured the status, never missing
  the way its other effects can. An item's cure is unaffected — RPG_RT
  genuinely never rolls one, and this codebase still doesn't. Covered by
  new `scripts/rpg2k_logic_check.rb` checks.
