- **bc2cpp**: the battle scene's `@ui[:foes]` record field is declared `Array`,
  traced through `Game::Troop.new(...).members.map { }`, so its `map`/`size`
  sends compile against Array instead of an owner call.
