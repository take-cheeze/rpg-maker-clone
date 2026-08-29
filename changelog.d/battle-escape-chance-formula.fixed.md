- **The battle escape-chance roll now matches a reference implementation's
  escape-chance calculation exactly** (ported from that source, not
  independently confirmed against genuine RPG_RT under wine). Three
  divergences from the real `150 - 100·enemyAgi/partyAgi` formula are fixed
  together: a fallen battler is now still counted in its side's average
  agility (the reference sums over every
  member, not just the living ones — `Game::Battle#avg_agi` used to `reject`
  the dead, understating the average the moment anyone went down); the
  agility ratio is now rounded to the nearest percent rather than truncated
  (the reference finishes with a round-to-nearest-int helper, while
  this build did a plain integer divide — a 7-agi party against a 10-agi
  troop should read escape chance 7, not 8); and the chance is now computed
  once, at battle start (`Game::Battle#initialize`), instead of lazily on
  the first Flee attempt, matching the reference computing it
  exactly once before any turn runs, so a stat-altering
  status landing mid-fight no longer skews an escape chance that real
  RPG_RT fixed before the first round. Covered by three new
  `scripts/rpg2k_logic_check.rb` checks, confirmed to fail against the
  pre-fix code before the fix.
