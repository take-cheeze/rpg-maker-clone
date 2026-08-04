- **Saves exported as `Save<N>.lsd` can now be loaded by the genuine
  `RPG_RT.exe`.** `Game::State#to_lsd` defaulted the file-screen date to `0.0`,
  and zero on the OLE-automation scale is 1899-12-30 — which RPG_RT reads as an
  *empty file slot*, so it silently ignored the save and left "Continue" dead,
  with no error anywhere. The date now defaults to the current time.
  The cause previously recorded for this — that our five chunks against a real
  save's sixteen were simply too few — was wrong: a real save stripped to
  exactly those five chunks still loads. Swapping in one of our chunks at a time
  isolated the title chunk, then the single field. Pinned by
  `scripts/rpg2k_save_load_check.rb`, and the ADR 0021 write-up is corrected.
