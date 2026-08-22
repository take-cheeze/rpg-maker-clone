- **Battle:** an offensive Skill's HP damage is now halved (quartered under
  強力防御) against a defending target, matching RPG_RT's own
  `AdjustDamageForDefend` -- previously only a basic Attack and self-destruct
  got this treatment, so any attack skill (elemental spells, physical
  skills, drain skills) dealt full, un-halved damage to a guarding target. A
  skill's SP effect and its ATK/DEF/SPI/AGI stat-mod effects are unaffected,
  matching RPG_RT's own behavior there.
