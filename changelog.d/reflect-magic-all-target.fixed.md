- **An all-enemies/all-allies-scope Skill now honours "Reflect Magic"
  (RPG2003) too, redirecting the whole volley onto the caster's entire
  living party instead of any of its originally-selected targets.**
  Previously only a single-target Skill's own reflect redirect was
  implemented; a group-scope Skill's own `#apply_command_all` ignored the
  state entirely. Ported from EasyRPG Player's
  `AlgorithmBase::ReflectTargets` (`AddTargets(&source->GetParty(), true)`):
  the instant any still-pending target in the volley carries Reflect Magic,
  every originally-targeted battler goes unhit and the caster's own side is
  hit in their place — replaced outright, not added on top of the original
  group, as an earlier reading of the same source had guessed. Each
  redirected hit reuses the reflecting target's own precomputed damage
  while its elemental multiplier/variance/absorb still resolve fresh
  against whichever new target it lands on; SP is still spent exactly once.
  Covered by a new `scripts/rpg2k_logic_check.rb` check, confirmed to fail
  against the pre-fix code before the fix.
