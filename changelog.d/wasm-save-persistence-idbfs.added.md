- **Browser build**: save data now survives a page reload or a closed tab.
  Every maker's save files are mirrored into the browser's IndexedDB (via
  Emscripten's `IDBFS`), keyed by the loaded project, and restored onto
  `/game` right before that project starts. See
  [ADR 0064](docs/adr/0064-wasm-save-persistence-idbfs.md).
