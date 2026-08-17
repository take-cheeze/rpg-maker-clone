- The **RPG2003 automatic battler placement** (`battlecommands.placement == 1`)
  now seats each party member's battle sprite on the grid slot from EasyRPG's
  `CalculateBaseGridPosition` / `Calculate2k3BattlePosition`
  (src/game_battle.cpp) — keyed by the member's party index/size and the
  encounter terrain's grid fields (terrain chunks 46-48), with the reference's
  own no-terrain defaults (112 / 392 / 16000) when no terrain is named —
  instead of falling back to the manual `battle_x`/`battle_y` (that fallback
  is now reserved for `placement == 0`). Ported with EasyRPG's grid table 0
  and its integer-truncation; the front-row actor path is done (the back-row
  offset and the pincer/surround enemy tables need the row derivation and
  battle conditions this runtime does not model). mtf-meido-action uses
  placement 1, so its real gauge battle exercises it. Covered by new
  `rpg2k_scene_check.rb` checks (lone and two-member grid slots; manual
  placement unchanged).
