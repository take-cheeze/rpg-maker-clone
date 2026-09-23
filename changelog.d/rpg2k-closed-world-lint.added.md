- **RPG2k closed-world lint** (`scripts/rpg2k_closed_world_lint.rb`): flags
  dynamic Ruby (`method_missing`, computed `send`, `const_get`, ivar
  reflection, `define_method`, `eval`, rescue modifiers) in the code bc2cpp
  compiles, against a baseline that may only shrink. Runs in CI. See
  `docs/rpg2k-closed-world-lint.md` and ADR 0212.
