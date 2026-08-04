- **Pictures shown when a game was saved are restored on Continue.** They were
  dropped on load, on the reasoning that a game's HUD pictures get re-shown by
  parallel events straight after — true of a HUD, false of a save taken
  mid-cutscene, where the event that showed the picture has already run.
  Resuming Nepheshel's opening, the genuine `RPG_RT.exe` drew the backdrop and
  we drew black. `LCF::Schema::SAVE_PICTURE` now models the picture's centre
  position: the save's double-valued slots were undocumented, and fields
  **31/32** were identified as the live position by rewriting each candidate
  pair in a real save and diffing the resumed frame against the unedited one.
  The picture region of that frame is now pixel-identical to RPG_RT.
