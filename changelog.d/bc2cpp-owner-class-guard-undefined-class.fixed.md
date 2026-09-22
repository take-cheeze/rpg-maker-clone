- **bc2cpp**: an exact-class guard naming a class that is not defined in the
  running game (for example `Game::Map` in an RGSS game) now simply does not
  match instead of raising `NameError: uninitialized constant Game`. This made
  every `RPGMAKER_BC2CPP=1` build fail `--rgss_effect_probe`. See ADR 0196.
