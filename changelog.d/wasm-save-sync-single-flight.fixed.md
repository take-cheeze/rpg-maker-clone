- **Browser build**: fixed the page hanging while saving (most visible in RPG
  Maker MV/MZ, whose save flow can write `save/websave.json` several times in
  a row). Two separate bugs caused this: Emscripten's `IDBFS.syncfs` has no
  re-entrancy guard, so two overlapping calls raced the same IndexedDB
  reconcile and could leave a callback that never fires (every `syncfs` call
  now goes through a single-flight queue instead); and the save-mirroring
  hook read the save file back from `/game` to stage it, which closed that
  same file and re-fired the hook on itself, spinning into an infinite,
  page-freezing microtask loop (now guarded the same way the restore path
  already was). See
  [ADR 0064](docs/adr/0064-wasm-save-persistence-idbfs.md).
