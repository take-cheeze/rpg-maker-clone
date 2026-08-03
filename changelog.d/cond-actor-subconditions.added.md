- **Conditional Branch** now evaluates the RPG2000 **actor (hero)**
  sub-conditions instead of only "is in party": whether the actor's name equals
  the command's string, whether its level is at least a value, and whether its
  HP is at least a value. Skill / equipment / state sub-conditions remain
  unmodelled and evaluate to false, as does a stat check on an actor not in the
  party. Covered by new checks in `scripts/rpg2k_logic_check.rb`.
