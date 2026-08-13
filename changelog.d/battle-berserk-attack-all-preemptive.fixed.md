- **A Berserk-style forced "attack enemy" restriction now collapses an
  attack-all weapon down to its single forced target and drops the weapon's
  own "always acts first" turn-order jump**, matching the site's
  デフォ戦botまとめ trivia: a forced restriction "overrides target selection
  but still honour[s] 'hits twice'/'ignores evasion,' while Berserk
  additionally collapses an 'attack all' weapon down to a single target and
  disables 'always acts first'." `Game::Battle#strike`
  (`mruby-rpg2k/mrblib/game.rb`) previously spread an attack-all weapon
  across the whole opposing side under *both* the attack-enemy (Berserk) and
  attack-ally (Confusion) restrictions alike, and `#preemptive_boost?` kept
  the preemptive turn-order jump for both too; both are now scoped to
  attack-ally only, matching Confusion's still-normal spread while Berserk
  forces a single hit with no jump. The restricted branch also switched from
  a bare `#deal_attack` to the same `#swing` an ordinary Attack uses, so a
  dual-wield weapon's extra hit — previously dropped under either forced
  restriction, an unconfirmed simplification the trivia turns out to
  contradict — now lands under both. Covered by four new `scripts/
  rpg2k_logic_check.rb` checks (Berserk plus attack-all hits one target; a
  preemptive weapon's jump is dropped under Berserk; Berserk still swings a
  dual-wield weapon twice; a confused, attack-all, dual-wield attacker swings
  twice per target), all four confirmed to fail against the pre-fix code.
