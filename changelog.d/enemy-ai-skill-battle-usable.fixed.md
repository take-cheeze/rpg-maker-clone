- **Battle:** An enemy's action pattern no longer casts an Escape/Teleport-
  type skill, or a Switch-type skill whose battle-occasion flag is off --
  matching RPG_RT's own `EnemyAi::IsActionValid`/`Algo::IsSkillUsable`, such
  an action is excluded from the weighted draw entirely, the same as it is
  for a field/battle actor cast.
