- **Decoded RPG2003's Battle Type field (database chunk 0x1D field 7)**, the
  editor option that picks between the traditional status-window-only battle
  screen and the alternate sprite/gauge presentation. `battlecommands.battle_type`
  now reads back as `0`/`1`/`2` (traditional/alternative/gauge) instead of
  going unread; `Game::Party#alternate_battle_layout?` exposes whether a
  database asks for the alternate presentation. This is foundational only —
  no rendering reads it yet, so every game still draws the existing
  status-window battle screen regardless of what it asks for. Covered by a
  new `scripts/rpg2k_logic_check.rb` check.
