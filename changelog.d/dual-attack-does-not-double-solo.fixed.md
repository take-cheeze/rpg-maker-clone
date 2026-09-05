- **A lone equipped `dual_attack` (二刀流) weapon no longer doubles a basic
  Attack's swing count.** `Game::Actor#strike_count`'s single-weapon branch
  multiplied by `dual_attack? ? 2 : 1`, so any actor with exactly one
  `dual_attack`-flagged weapon equipped (and nothing in the shield slot)
  swung twice. Confirmed against genuine RPG_RT.exe under wine: a custom
  100%-hit `dual_attack` weapon equipped alone against a passive, durable
  enemy logged exactly one damage line per Attack command, in the same band
  a matching non-`dual_attack` control weapon produced — never a second
  line or a roughly-doubled total — and the same result held re-run with
  Nepheshel's own real `dual_attack` weapon (item 36, サクリファイス)
  equipped solo instead of the custom probe. Fixed by dropping the
  `dual_attack? ? 2 : 1` multiplier from `#strike_count`'s single-weapon
  return; `#dual_attack?` itself is unchanged and still read by
  `#strike_count`'s own two-weapon branch, which is left untouched — a
  `#double_hand?` actor with a real weapon in *both* the weapon and shield
  slots is a separate, still not independently confirmed case (a wine
  capture of that setup showed a single combined, higher-damage line rather
  than either a no-op or two separate lines, leaving its exact formula
  ambiguous from one data point). Covered by rewriting the existing "a
  二刀流 weapon swings twice" `scripts/rpg2k_logic_check.rb` check (now "a
  solo 二刀流 weapon does not swing twice") plus two further checks that
  had used a solo `dual_attack` weapon merely as a vehicle for a second
  swing, switched to a genuine two-weapon-slot vehicle instead, confirmed
  to fail against the pre-fix code.
