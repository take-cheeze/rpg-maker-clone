- **bc2cpp**: the battle and save-slot mrblib spelled `reject(&:dead?)`, `select(&:defending)`, `reject(&:hidden)`
  and `each(&:update)` as Symbol-to-proc blocks, which keep `dead?`, `defending`, `hidden` and every `update` a
  possible by-name lookup. They are plain blocks now: the closed host's method table loses 6 entries (905 to 899)
  and the 480 by-name `dead?` sends of a battle run are gone.
