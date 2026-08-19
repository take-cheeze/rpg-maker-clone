- **RPG2003 battles:** A battler's per-battle ATK/DEF/SPI/AGI stat
  modifier (from a buff/debuff skill) and any attribute-defence rank
  shift now reset the instant it dies, matching RPG_RT — the same
  Knockout reset already applied to the active-time gauge. Previously an
  ally buffed (or debuffed) mid-fight, then killed and revived within the
  same fight, kept fighting with the stale pre-death modifier still
  active instead of a clean slate. Covered by a new
  `scripts/rpg2k_logic_check.rb` check.
