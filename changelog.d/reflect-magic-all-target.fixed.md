- **An all-enemies/all-allies-scope Skill no longer redirects onto the
  caster's entire living party for "Reflect Magic" (RPG2003)**, reverting a
  prior revision of this fragment alongside the single-target reflect
  revert. The same genuine wine capture that falsified the single-target
  redirect falsifies this group-scope shape too — `reflect_magic` does not
  appear to change a Skill's targeting at all, in either shape. Reverted by
  removing the redirect from `Game::Battle#apply_command_all` and deleting
  the now-dead `#reflecting_target_all` method. Covered by rewriting the
  existing `scripts/rpg2k_logic_check.rb` check in place.
