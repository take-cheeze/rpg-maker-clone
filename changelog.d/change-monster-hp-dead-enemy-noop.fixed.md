- **Battles:** Change Monster HP is now a complete no-op against an
  already-downed enemy, matching real RPG_RT — a further damaging hit used to
  silently revive it to 1 HP instead of leaving it dead. Also fixed the
  command's percentage-amount mode to scale off the target's current HP, not
  its maximum, matching RPG_RT. Covered by new `scripts/rpg2k_logic_check.rb`
  checks.
