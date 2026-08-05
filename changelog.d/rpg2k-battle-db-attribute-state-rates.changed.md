- RPG Maker 2000: elemental damage and status infliction now read their **rank
  rates from the database** instead of a hardcoded table. `Game::Battle` takes an
  optional attribute (`property`) table and, via `attr_rate` / `state_rate`, reads
  each attribute's own `a_rate` .. `e_rate` and each state's `situation`-table
  rates for a target's A..E rank — so a game that customises an element's or a
  status's effectiveness curve is honored, falling back to the RPG2000 defaults
  (attributes 300/200/100/50/0, states 100/80/60/30/0) only when no table is
  supplied. This also corrects the default **attribute** rank-A/B multipliers,
  which were previously 200%/150% rather than liblcf's 300%/200%. Wired into the
  live battle from the database `property` and `situation` tables. Covered by new
  `scripts/rpg2k_logic_check.rb` checks (a database attribute and a database state
  each override the default rate), with the existing elemental checks updated to
  the corrected defaults.
