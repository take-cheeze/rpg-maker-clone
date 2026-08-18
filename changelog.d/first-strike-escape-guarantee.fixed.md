- **Battle scene:** a first-strike (ambush) encounter's opening Escape is now
  actually guaranteed to succeed, matching real RPG_RT — it used to still
  roll the ordinary agility-based chance, so a first-strike battle against
  fast enemies could floor the roll at 0% and trap the party in a fight it
  should have been able to walk away from unconditionally. `Game::Battle`
  gained a `#first_strike?` predicate and the battle scene's Escape command
  now passes it through as the `preemptive` flag the model layer already
  supported but was never given. Covered by new `scripts/rpg2k_logic_check.rb`
  and `scripts/rpg2k_scene_check.rb` checks.
