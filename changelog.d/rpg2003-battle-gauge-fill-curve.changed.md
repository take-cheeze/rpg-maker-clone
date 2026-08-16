- The **RPG2003 gauge battle now charges at the real RPG_RT 2003 pace**, not
  the placeholder linear curve: `Game::Battle#advance_gauges` ports EasyRPG's
  `Game_Battle::UpdateAtbGauges` (src/game_battle.cpp) exactly —
  `GAUGE_MAX` is 300000, and each battler's per-frame increment is
  `GAUGE_MAX / (sum_agi / (agi + 1))` over every non-hidden battler's AGI
  (all integer-truncated), so the whole field charges together on a common
  pace scaled by relative AGI rather than each battler charging at its own
  absolute rate, a do-nothing-restricted ally never charges (`CanAct()`),
  and faster battlers still reach full first. Covered by reworked
  `rpg2k3_battle_gauge_check.rb` checks pinning the exact increments, the
  143-vs-273-tick fill ordering, full-and-stays, and the dead/restricted
  no-charge rules.
