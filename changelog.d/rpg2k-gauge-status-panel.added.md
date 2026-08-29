- **RPG2003's gauge battle-screen layout (`battlecommands.battle_type == 2`)
  now replaces the party status panel with the real "gauge card" layout**
  instead of the plain text status window: each living party member's face
  (from the actor's `faceset_name`/`faceset_index`), an HP bar and an SP bar,
  and their current values as digit-glyph numbers, all drawn from the
  database's own `System2` graphic. Ported column-for-column from a
  reference implementation's own gauge-card drawing (not independently
  confirmed against genuine RPG_RT under wine) — including the exactly-full
  gauge reading a visually distinct "full" fill tile, and its exact
  leading-zero-suppression cascade. `battle_type == 1` (alternative) is
  unchanged and keeps the existing text status window; a database naming no
  `System2` graphic (or one that fails to load) falls back to the text status
  window instead of drawing a blank or crashing. The ATB/wait gauge row RPG_RT
  also draws is out of scope — this runtime has no ATB/wait-timer subsystem.
  Covered by new checks in `scripts/rpg2k_logic_check.rb` and
  `scripts/rpg2k_scene_check.rb`.
