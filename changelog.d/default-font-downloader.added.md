- **A default UI font** for projects that ship none of their own.
  `scripts/download-default-font.bash` fetches M PLUS 1p Regular (SIL Open Font
  License, pinned by commit and SHA-256) into `assets/fonts`, the same way the
  MIDI patch set is fetched rather than committed. RPG Maker XP/VX select their
  font by family name from the project's `Fonts/` folder and MV/MZ from
  `fonts/`; a project that ships neither used to draw every window with the
  built-in 12px shinonome bitmap font whatever size it asked for, and now falls
  back to a real TrueType face at the right size. A project's own font still
  wins, and RPG2000/2003 is deliberately untouched — its text keeps rendering
  with shinonome, whose metrics match RPG_RT's MS Gothic. Validated by the new
  `default_font` CTest case (`scripts/check_default_font.rb`), which skips
  cleanly when the font was never downloaded; override it with
  `RPG_DEFAULT_FONT`, and preload it into the web build with
  `-DWASM_DEFAULT_FONT=ON`.
