- **Field menu:** a medicine or skill that both revives a downed party
  member and restores HP in the same use no longer over-heals by 1 HP --
  matching RPG_RT's own `Game_Battler::UseItem`/`UseSkill`, which add
  `recovery - 1` on top of the revive's 1 HP floor, not the full recovery
  amount. Previously a revival item/skill landed the target 1 HP higher
  than real RPG_RT would.
