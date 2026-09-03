- **Confusion (混乱) also collapses an `attack_all` weapon down to a single
  target, instead of spreading it across the attacker's own side.** A prior
  cycle had confirmed this for Berserk by wine A/B but left Confusion's own
  half of the same claim untested, keeping the old spread behavior. This
  cycle ran the same genuine RPG_RT.exe test (Nepheshel) with a Confused
  leader instead: against a two- and a three-member party, the forced
  attack always logged exactly one target line per swing — whether the
  random forced target ended up being the attacker itself or another party
  member — never two lines in the same swing. `Game::Battle#strike`
  (`mruby-rpg2k/mrblib/game.rb`) now narrows both forced restrictions to
  `#swing` unconditionally, the same path an unforced single-target Attack
  already uses; dual-wield's extra swing still applies to that one target.
  See `docs/TODO.md`'s "Still open, genuinely needs wine" entry for the
  full methodology.
