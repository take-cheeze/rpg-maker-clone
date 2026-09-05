- **A weapon's `attack_all` (全体化) flag no longer spreads a basic Attack
  across every living enemy — for an unforced Attack, not just the
  already-fixed forced-restriction (Berserk/Confusion) case.**
  `Game::Battle#strike`'s unforced branch called `swing_side(b,
  side_targets(target), hits)` whenever the wielder's weapon carried
  `attack_all`, hitting every living member of the target's side in one
  swing. Confirmed against genuine RPG_RT.exe under wine: a custom
  100%-hit `attack_all` weapon against a two-enemy troop showed the
  control build's own target-select menu skipped entirely once the flag
  was set, but every round's own damage line still named exactly one
  specific enemy — never both — across five consecutive rounds in one
  fixture and a sixth in a second, independently-built fixture with the
  troop's member order swapped (which moved *which* enemy took the hit,
  ruling out a fixed name/identity coincidence). Fixed by removing the
  `attack_all` special case from `#strike`'s unforced branch entirely
  (now always a plain `#swing`); `side_targets`/`swing_side` are dead code
  and removed, and `#queue_auto_battle_attack`'s own `attack_all`
  short-circuit (which existed only to route through the now-removed
  spread dispatch) is removed too, so an `attack_all`-wielding auto-battler
  now ranks its target the same way any other weapon does. Covered by
  rewriting the existing "全体化 weapon spreads a basic Attack" `scripts/
  rpg2k_logic_check.rb` check to assert the single-target outcome instead,
  confirmed to fail against the pre-fix code.
