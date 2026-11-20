- **bc2cpp**: the battle scene's `@ui[:allies]` and `@ui[:items]` record fields
  are declared `Array`, checked through the calls that produce them, so their
  `each`/`size`/... sends compile against Array instead of an owner call.
