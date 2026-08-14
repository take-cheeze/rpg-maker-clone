- **A state flagged "Reflect Magic" (RPG2003) now bounces a single-target
  Skill back onto its own caster.** `reflect_magic` (state schema field 37)
  was parsed but never read anywhere in the battle engine. Ported from
  EasyRPG Player's `Game_Battler::HasReflectState` /
  `Game_BattleAlgorithm::Skill::IsReflected`: a genuine Skill cast (not an
  item-cast effect) whose target carries the state and starts on the
  opposite side from its caster now redirects onto the caster instead,
  before any hit-chance/elemental/variance math runs — so the skill still
  rolls its own accuracy and damage normally, just against the new target.
  Works symmetrically for both player- and enemy-cast skills. Scoped to a
  single-target Skill only; an all-enemies-scope skill's own group-wide
  reflect behaviour (redirecting the caster's entire party) is a separate,
  unaddressed shape. Covered by a new `scripts/rpg2k_logic_check.rb` check,
  confirmed to fail against the pre-fix code before the fix.
