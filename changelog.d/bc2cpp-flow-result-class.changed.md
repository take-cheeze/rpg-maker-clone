- **bc2cpp** drops 45 by-name sends from the shipped build: a call result the
  exact-class flow proves to be an Array/Hash/String/Range now takes the typed
  direct call, `&:symbol` block arguments keep core collection results exact, and
  `Game::Battle#turn_order` returns a plainly fresh Array so `@queue` is a class
  pool. See `docs/adr/0407-bc2cpp-flow-result-class-and-symbol-blocks.md`.
