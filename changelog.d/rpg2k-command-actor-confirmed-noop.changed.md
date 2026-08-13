- RPG Maker 2000: confirmed that a battle-event page's **`command_actor`**
  (chosen battle command) condition never firing is correct RPG2000 battle
  behaviour, not a gap to close. EasyRPG's `AreConditionsMet` only evaluates
  the condition when handed the battler whose action triggered the check
  (`if (!source) return false;`), and `Scene_Battle_Rpg2k::CheckBattleEndAndScheduleEvents`
  — the only page-scheduling call site RPG2000's own battle scene has —
  always calls `ScheduleNextPage(nullptr)`. A real `source` only ever exists
  in `Scene_Battle_Rpg2k3`, the separate RPG2003 ATB battle scene this
  runtime does not model, so a page gated on `command_actor` is never
  satisfiable under RPG2000's own battle system at all. Reworded the code
  comment, the `docs/TODO.md` note and the covering
  `scripts/rpg2k_logic_check.rb` check to say so with a citation instead of
  describing it as an evaluation-timing limitation still to be built.
