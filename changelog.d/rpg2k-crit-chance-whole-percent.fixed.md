- **Critical-hit chance now truncates to a whole percent before rolling**,
  instead of preserving fractional basis-point precision RPG_RT itself
  discards. Confirmed against EasyRPG Player's source: RPG_RT sums an actor's
  base rate and weapon bonus as a float, then truncates the combined result to
  a whole percent before ever rolling — the fractional remainder is thrown
  away regardless of which term produced it. A plain 1-in-30 actor with no
  weapon bonus previously landed a critical hit 3.33% of the time here,
  against RPG_RT's flat 3% — an eleven percent relative inflation, present for
  almost every critical rate in both games.
