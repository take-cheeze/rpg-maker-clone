- Fixed `Graphics.isFontLoaded('GameFont')` hanging RPG Maker MV's `Scene_Boot`
  forever on projects whose corescript uses the classic canvas-`measureText`
  font-ready check: our `measureText` backed every font shorthand with the
  loaded game font regardless of the requested family, so the check's two
  comparison widths (`'GameFont, sans-serif'` vs plain `'sans-serif'`) were
  always identical and never diverged. `measureText`/`fillText`/`strokeText`
  now only use the real font metrics when the shorthand actually names
  "GameFont", falling back to the same rough per-character estimate used when
  no game font is loaded otherwise. Found against a real, downloaded MV
  release that had been packed into a single Enigma Virtual Box executable.
