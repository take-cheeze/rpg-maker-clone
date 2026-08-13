- **A move-route "Face Direction" sub-command now always turns the sprite,
  even right after a "Direction Fix ON" earlier in the same route.**
  `Game::MoveRoute#apply_command`'s Face Up/Right/Down/Left/Random/Hero/
  Away-from-Hero sub-commands routed through `Character#face`, which
  respects the Direction Fix lock (`facing_locked`) — correct for the
  *movement-driven* facing changes `#move`/`#jump`/`#move_diagonal` make as a
  side effect, but not for an explicit Face Direction command, which RPG_RT
  always honours regardless of the lock (the move-route Turn Right/Left/180/
  Random sub-commands already bypassed it by writing `@direction` directly).
  Fixed with a new lock-ignoring `Character#face!`, now used by all seven
  Face Direction sub-commands. Covered by a new `scripts/rpg2k_logic_check.rb`
  check, confirmed to fail against the pre-fix code before the fix.
