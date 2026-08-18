- **RPG2000/2003 actors:** A newly learned skill now sorts into the
  actor's skill list by id, matching RPG_RT, instead of simply being
  appended in learn order. This was invisible in the Skill menu (already
  sorted for display) but changed the RNG-jitter draw order for Auto
  Battle's own skill-vs-attack ranking, which could pick a different
  skill on a near-tie. Covered by a strengthened
  `scripts/rpg2k_logic_check.rb` check.
