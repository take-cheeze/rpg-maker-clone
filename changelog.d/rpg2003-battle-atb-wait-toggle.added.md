- The **RPG2003 Wait/active toggle is implemented** (ADR 0054's follow-up).
  The switch is the save-system `SaveSystem.atb_mode` field (LSD chunk 140),
  not a Battle Commands database field — liblcf's `fields.csv` has no `wait`
  entry on that table — so the schema now decodes it and `Game::State`
  carries it, writing the 2003-only chunk out only when non-zero. The field
  menu's **Wait command (id 8)** now appears for RPG2003 games that list it,
  showing the current mode via the `wait_on` / `wait_off` terms and flipping
  `atb_mode` on confirm. In a gauge battle, wait mode (the default) freezes
  the charge gauges while a command menu is open, while active mode keeps
  them filling and lets a ready non-controllable combatant's action
  **interrupt** the menu — mirroring a reference implementation's
  ATB-accumulation and action-scheduling logic, not independently confirmed
  against genuine RPG_RT under wine. Covered by new `rpg2k_scene_check.rb` checks
  (freeze / active-fill / menu-interrupt / Wait-row toggle) and an
  `rpg2k_save_load_check.rb` round-trip.
