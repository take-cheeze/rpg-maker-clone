- **An RPG2003 database now uses RPG2003's own EXP curve**, instead of
  always running RPG2000's regardless of edition. Confirmed against EasyRPG
  Player's source: the two editions use structurally different
  formulas — RPG2000's compounds a running base by an inflation factor each
  level, while RPG2003's is linear in the level index — not a shared curve
  with an edition-gated constant. Every actor in an RPG2003 database
  previously levelled up on RPG2000's thresholds throughout the game, off by
  as much as a third at the very first level and diverging further at every
  level after.
