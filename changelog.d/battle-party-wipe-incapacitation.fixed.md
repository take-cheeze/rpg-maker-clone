- **A battle now ends in defeat (or victory) the instant every battler on a
  side is permanently unable to act, not only once every one of them is
  literally at 0 HP** — a fully-Stoned party loses even though nobody was
  ever damaged, matching デフォ戦botまとめ's "'party wipe' for game-over
  purposes is defined as 'every member is both unable to act and does not
  recover naturally,' not literally 'every member's HP is 0.'"
  `Game::Battle#alive?` (`mruby-rpg2k/mrblib/game.rb`) only ever checked
  `#out_of_play?` (dead or hidden), so a party entirely afflicted by a "do
  nothing" restriction state that never wears off on its own read as still
  fighting and ground all the way to the `MAX_ROUNDS` safety net before
  finally resolving as a loss. A new `#incapacitated?` — dead/hidden, or
  carrying a `RESTRICTION_DO_NOTHING` state whose `auto_release_prob` is
  0 — now backs `#alive?` instead; a do-nothing state that *can* still shake
  itself off on its own (Sleep, Paralysis with a nonzero `auto_release_prob`)
  does not count, so the fight correctly keeps running while there is still
  a chance someone wakes up. Applies symmetrically to enemies too. Covered by
  three new `scripts/rpg2k_logic_check.rb` checks, one confirmed to fail
  against the pre-fix code before the fix.
