- **Battle**: a healing/recovery skill's elemental `attributes:` are now
  threaded through and applied to its recovery amount, the same way an attack
  skill's already were. `Game::Party#battle_skill_command`'s recovery branch
  now carries the skill's own `attributes:`, and `Game::Battle#apply_skill_hit`
  scales the HP/SP recovery by the target's attribute resistance before
  variance, ported from a reference implementation whose attribute
  multiplier runs unconditionally, with no heal-vs-damage gate — not
  independently confirmed against genuine RPG_RT under wine. This is what a
  database uses to make a character harder/easier to
  heal via a tagged heal plus a custom resistance, or to build a
  caster-excluding MP-restore skill via 0% self-resistance.
