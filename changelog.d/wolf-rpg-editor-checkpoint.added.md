- **WOLF RPG Editor (ウディタ/Woditor)** `Checkpoint`(99) — the second most
  common unimplemented command by real frequency (49 occurrences) — is now
  a no-op alongside `Blank`(0). It is a pure event-editor bookmark/
  navigation aid ("チェックＰ追加"/"次チェックＰへジャンプ") with no
  runtime effect at all, matching the wolfrpg-map-parser crate's own
  unit-variant model. See `docs/adr/0078-wolf-rpg-editor-checkpoint.md`.
