- **Battle:** a charged enemy is now guaranteed a single doubled Attack, the
  same way real RPG_RT forces it — it used to still run its ordinary AI
  pattern and could end up Defending, casting a Skill, or otherwise never
  attacking at all, silently wasting the charge for nothing. `Game::Battle
  #strike` now skips pattern selection outright while charged, falling
  through to the same forced-Attack path an empty pattern already used.
  Covered by corrected/new `scripts/rpg2k_logic_check.rb` checks.
