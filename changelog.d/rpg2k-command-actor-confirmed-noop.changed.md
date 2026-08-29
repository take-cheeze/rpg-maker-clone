- RPG Maker 2000: confirmed that a battle-event page's **`command_actor`**
  (chosen battle command) condition never firing is correct RPG2000 battle
  behaviour, not a gap to close. A reference implementation's own
  condition-evaluation logic only evaluates the condition when handed the
  battler whose action triggered the check, returning false with no such
  battler, and RPG2000's own battle scene's only page-scheduling call site
  always schedules the next page with no such battler at all. A real
  triggering battler only ever exists in the separate RPG2003 ATB battle
  scene this runtime does not model, so a page gated on `command_actor` is
  never satisfiable under RPG2000's own battle system at all (ported from a
  reference implementation, not independently confirmed against genuine
  RPG_RT under wine). Reworded the code
  comment, the `docs/TODO.md` note and the covering
  `scripts/rpg2k_logic_check.rb` check to say so with a citation instead of
  describing it as an evaluation-timing limitation still to be built.
