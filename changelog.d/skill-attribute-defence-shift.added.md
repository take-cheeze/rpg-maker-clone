- **A skill flagged "attribute defense up/down" now shifts the target's
  elemental rank.** `Game::Party#battle_skill_command` computes the shift (one
  attribute-defence step, direction from `reverse_state_effect`) for both
  attack and buff/recovery skills, and `Game::Battle#apply_attr_shift` applies
  it capped at ±1 from the rank the battle started at
  (`Combatant#attr_base_ranks`) — repeat casts don't stack past the cap. It
  resets at battle end for free: a `Combatant`'s `attr_ranks` is a fresh copy
  of the database row, never written back to the actor. The direction (which
  way `reverse_state_effect` shifts) is this build's own reading — reusing the
  same polarity flag a skill's state effects already use — not confirmed
  against real RPG_RT or either downloaded test bed, since neither ships a
  skill with the flag set. Covered by a new `scripts/rpg2k_logic_check.rb`
  check.
