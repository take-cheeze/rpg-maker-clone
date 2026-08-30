- **A battle skill's `reverse_state_effect` flag now actually flips its
  state_effects on an RPG2003 database.** A reference implementation's
  skill-execution logic computes `heals_states =
  is_positive_scope ^ (rpg2003? && skill.reverse_state_effect)`, not
  independently confirmed against genuine RPG_RT under wine — on
  RPG2000 the XOR's right-hand term is always false, collapsing to the plain
  "ally scope cures, enemy scope inflicts" rule this codebase already
  modelled, but a real RPG2003 database with the flag set can invert either
  scope: a self/ally skill inflicts its listed states on its own side (a
  self-scoped Berserk that confuses its own caster) and an enemy skill cures
  its target's states instead of adding new ones. `Game::Party
  #battle_skill_command` now computes `heals_states` the same way, gated on
  the existing `#rpg2003?` accessor, and `Game::Battle#apply_skill_hit`'s
  attack/recovery branches both honour whichever of `cured:`/`inflict:` it
  produced rather than assuming one from the branch alone. The field-skill
  path was checked too in that reference and found already correct —
  its own cure/inflict polarity carries no RPG2003 gate, matching what this
  codebase already did there. Covered by new `scripts/rpg2k_logic_check.rb`
  checks, confirmed to fail against the pre-fix code before the fix.
