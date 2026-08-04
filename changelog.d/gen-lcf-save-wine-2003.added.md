- Real `Save<N>.lsd` fixtures can now be generated **headlessly** and for the
  **RPG Maker 2003** edition. `scripts/gen-lcf-save-wine.bash` boots an RPG
  2000/2003 game's EasyRPG Player under wine + Xvfb + a window manager and uses
  the **test-play debug menu** (F9 -> Save) to write a genuine `LcfSaveData` from
  anywhere -- bypassing both Nepheshel's Gate-only saving and the 2003 test
  games' menu-disabled intro, then runs `scripts/lcf_save_check.rb` over the
  result. This closes the save-level 2003 validation deferred by ADR 0013: a real
  mtf-meido-action (RPG2003) save parses through the `SAVE_DATA` schema and
  round-trips into the runtime cleanly, the `SAVE_TITLE` hero HP matches party
  actor 1's saved HP, and every `SAVE_MAP_EVENT` position matches a defined,
  in-bounds event on the current map. The undocumented top-level chunks 102, 112
  and 200 are confirmed to appear in both editions' saves. See ADR 0017.
