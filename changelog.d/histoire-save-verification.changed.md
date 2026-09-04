- Generated a genuine `Save01.lsd` for histoire203 (`scripts/gen-lcf-save-wine.bash
  data/histoire203`, EasyRPG Player's F9 debug-menu Save under wine) and
  confirmed it end to end: `lcf_save_check.rb` parses it cleanly,
  `lcf_save_roundtrip.rb` reproduces it byte-exact and survives a live
  edit/reload, `rpg2k_save_load_check.rb` reconstructs a `Game::State` from it
  with no failures, and the built engine's own `--rpg2k_continue` resumes
  straight onto the saved map/position. The two still-undocumented chunks
  (112 `SavePanorama`, 200 a non-standard extension chunk) show the identical
  shape as kk1.12's own real capture — the same one-byte empty terminator for
  112, the same 5 bytes for 200 — on an unrelated, much larger database (774
  maps against kk1.12's 128), corroborating rather than contradicting the
  existing finding; `mruby-lcf/mrblib/schema.rb`'s own comment now cites both.
  `scripts/gen-lcf-save-wine.bash`'s own header note is corrected too: unlike
  Nepheshel, histoire203 needs no demo-skip/name-entry driving of its own
  before the generic F9-save path reaches a saveable state — whether that
  step is needed turns out to depend on the individual game's own opening,
  not its RPG2000/2003 edition.
