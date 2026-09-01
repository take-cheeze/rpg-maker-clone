- **Berserk (暴走) once again collapses an `attack_all` weapon down to a
  single target**, reverting a prior "fix" that had made it spread across
  the whole enemy side instead. Confirmed this time by an actual wine A/B
  against genuine RPG_RT.exe (Nepheshel): a Berserk-forced leader wielding
  an attack-all weapon against two Slimes only ever logs one target's own
  hit/evade line, captured at 0.15s-per-frame resolution to rule out a
  missed second message. Confusion (混乱) is unaffected and still spreads an
  `attack_all` weapon across the attacker's own side, matching this
  codebase's existing checks. `Game::Battle#strike`
  (`mruby-rpg2k/mrblib/game.rb`) narrows only the attack-enemy restriction
  back to `#swing`; see `docs/TODO.md`'s "Possible dispute with an
  already-shipped fix" entry for the full methodology.
