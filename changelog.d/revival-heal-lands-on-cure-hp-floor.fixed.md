- **RPG2003 battles:** A revival skill or item now correctly revives an
  ally who took heavy overkill damage, matching RPG_RT. Previously the
  skill's heal was added directly onto the target's stale (possibly
  deeply negative) HP before the status cure ran, so a revival item could
  fail to actually bring HP above zero even though it was consumed and
  reported the target's Knockout cured. The heal now lands on top of the
  cure's own HP-to-1 floor instead, the same order RPG_RT applies them
  in. Covered by new `scripts/rpg2k_logic_check.rb` checks.
