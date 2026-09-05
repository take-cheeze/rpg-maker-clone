- **A state flagged "Reflect Magic" (RPG2003) no longer bounces a
  single-target Skill back onto its own caster**, reverting a prior
  revision of this fragment. That revision ported a reference
  implementation's own reflect-state handling without independently
  confirming it against genuine RPG_RT, on the theory that a status parsed
  but never read was meant to redirect an enemy-cast Skill back at its
  caster. Confirmed wrong under wine: a party member carrying a
  freshly-authored `reflect_magic`-flagged state kept taking an enemy's own
  single-target Skill damage directly, across two separately-landed casts,
  never once redirecting it back onto the caster. Genuine RPG_RT does not
  appear to wire the flag into a Skill's own targeting at all. Reverted by
  removing the redirect from `Game::Battle#apply_command` and deleting the
  now-dead `#reflects_magic?`/`#reflects_skill?` methods. Covered by
  rewriting the existing `scripts/rpg2k_logic_check.rb` check in place, now
  asserting the flag is inert rather than asserting it redirects the hit.
