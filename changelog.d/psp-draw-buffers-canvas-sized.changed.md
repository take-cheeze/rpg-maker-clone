- **PSP: LVGL draw buffers are sized to the game's canvas instead of the
  panel.** The two partial-render buffers in `mruby-rgss/src/psp.cxx` were
  fixed 480×68×2 (64 KB each, 128 KB total) regardless of the logical display
  resolution. They are now computed at display-create time from the canvas
  (RPG2k's 320×240 fits 60 rows → ~38 KB per buffer, ~76 KB total), capped at
  the old 64 KB per buffer so an XP/VX canvas wider than the panel keeps
  fewer rows per flush rather than growing. See
  `docs/adr/0047-psp-memory-budget.md`.
