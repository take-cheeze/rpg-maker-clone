- **Change Parameters now tracks an unclamped running total underneath its
  displayed 1..999 (1..9999 for max HP/MP) clamp.** `Game::Actor#change_param`
  used to clamp and overwrite `@base[type]` on every call, permanently
  discarding how far past the limit the real total had gone — so lowering
  Attack by 2000 from a base of 3, then raising it back by 1000, landed at
  the clamp ceiling (999) instead of staying floored, even though the real
  total (3 - 2000 + 1000 = -997) is still deep underwater. Per yado.tk's
  `2000/デフォ戦botまとめ`, real RPG_RT keeps accumulating the true total and
  only clamps the effective/displayed value, so a partial raise after a big
  drop stays pinned at the old clamp until the raw total genuinely climbs
  back past it. Added a parallel `@base_raw` shadow that
  `#change_param` accumulates the signed delta on before clamping into
  `@base` (the value `#recompute_stats` and everything else still reads);
  `@base_raw` is reset alongside every wholesale replacement of `@base`
  (`#set_level`, and all three branches of `#change_class`'s param-mode
  handling), so a level-up or class change establishes a fresh baseline
  rather than carrying stale drift across it. Covered by a new
  `scripts/rpg2k_logic_check.rb` check, confirmed to fail against the
  pre-fix code before the fix.
