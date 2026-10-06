- **bc2cpp closed world**: `mruby-rpg2k` no longer dispatches stat modifiers,
  battler flags or the equip-menu stat rows through a computed `send`; they
  are literal `case` dispatches now, so the closed-world lint baseline drops
  its eight `Dynamic/Send` entries (ADR 0212).
