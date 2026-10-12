- **Battle (RPG2000/2003):** an enemy skill-ready check (`Game::Battle#enemy_skill_ready?`
  asks for the skill's command before a target is picked) no longer raises
  `undefined method 'evasion_up' for nil` from `Party#skill_to_hit` for a physical skill; with no
  target there is no agility or evasion term, so the caster-side hit rate is returned. The
  exception ended the whole battle in the Nepheshel and mtf-meido-action test beds.
