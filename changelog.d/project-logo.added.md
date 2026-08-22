- Added a project logo, **Sapphire Chip**: a cut-gem mark for the embedded
  `mruby` interpreter, drawn on the same 16x16 pixel grid the game maps
  themselves are built from (`assets/logo/sapphire-chip.svg`). It now heads
  `README.md`, sets the favicon on the Emscripten/WASM shell page
  (`src/shell.html`), and fills the PSP EBOOT's XMB icon slot, previously
  `ICON_PATH NULL` (`app/psp/CMakeLists.txt`, `assets/psp/icon0.png`).
