- **bc2cpp**: the battle scene's `@ui[:skills]` record field is declared `Array`,
  traced through `Party#battle_skills`'s and `Actor#skills=`'s declared (entry-checked)
  parameters, so its `map`/`length` sends and the `skills`/`reject` calls on those
  parameters compile without an owner call.
