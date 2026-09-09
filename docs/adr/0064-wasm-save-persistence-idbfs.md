# 64. Persisting wasm save data with IndexedDB (IDBFS)

Date: 2026-09-06

## Status

Accepted

## Context

The browser build (Emscripten) links only `-sFORCE_FILESYSTEM=1`, which
guarantees the default `MEMFS` backend and nothing else. `MEMFS` is purely
in-memory: every save a player writes during a session — RPG2000/2003's
`save<N>.mrb` (this engine's own Marshal dump) and its exported
`Save<NN>.lsd` sibling, RPG Maker XP/VX/VX Ace's stock `Save<N>.rxdata` /
`.rvdata[2]`, and RPG Maker MV/MZ's single `save/websave.json` (the
`localStorage` shim in `mruby-mvjs/src/mvjs.cxx`) — vanishes the moment the
tab reloads or closes. All of these write through plain C `fopen`/`fwrite`
against paths resolved relative to `GAME_DIR`, which is `/game` in the
browser build; there is no storage abstraction layer to intercept in one
place, and no persistence backend mounted at all.

`/game` is also not a stable place to persist wholesale: `src/shell.html`'s
loader unzips a fresh copy of whatever project the player picks into it on
every page load (or `--preload-file` bakes one in at build time), so it holds
the *entire* project's assets — art, audio, database files — not just save
data. Mounting a persistent filesystem directly on `/game` would durably copy
every one of those assets into IndexedDB as a side effect of the engine
merely reading them once at boot, growing the origin's storage quota without
bound and duplicating what the loader's own archive cache (Cache Storage,
keyed by the zip's URL) already covers.

## Decision

Link Emscripten's `IDBFS` backend (`-lidbfs.js`, `CMakeLists.txt`) and mount
it at a dedicated `/persist` directory, entirely separate from `/game`. The
shell page mirrors only files that are *shaped* like a save — matched by a
small, engine-specific set of root-level filename patterns plus MV/MZ's one
fixed nested path — into `/persist/<project-slug>/`, and syncs that directory
to IndexedDB. `<project-slug>` is derived from whatever the player loaded
(the zip URL/repo text, or the local filename), so two unrelated games do not
share a save slot.

The mirroring hook is Emscripten's `FS.trackingDelegate.onCloseFile`: every
file close under `/game` is checked against the save-shaped patterns, and a
match is copied into the matching path under `/persist/<slug>/` and (after a
500ms debounce, so a burst of writes — e.g. RPG2000's Marshal dump plus its
`.lsd` export — costs one flush) pushed to IndexedDB with `FS.syncfs(false,
…)`. This needed no changes to any save-writing code in any of the four
makers — LCF's own Ruby, the RGSS stock scripts, and MV/MZ's `js_write_file`
bridge all still just call `fopen`/`fwrite` exactly as before; the hook lives
entirely in the browser shell.

**`-sFS_DEBUG=1` is required, and easy to miss.** Every
`FS.trackingDelegate[...]` call site in Emscripten's own `library_fs.js` is
compiled out of `FS.open`/`close`/`write`/etc. entirely unless the `FS_DEBUG`
setting is on (its own doc comment: "Register file system callbacks using
trackingDelegate in library_fs.js") — assigning
`Module.FS.trackingDelegate.onCloseFile = ...` from `src/shell.html` still
succeeds either way, but without this flag the shipped runtime never reads it
back, so the hook silently never fires and nothing is ever mirrored. This was
caught only by testing the actual deployed Cloudflare preview by hand (saves
did not survive a reload); nothing in this repo's own CI build/link step
would have caught it, since `-sFS_DEBUG` does not affect whether the page
compiles or links. Despite the name, this is not a debug-only flag here — the
only other thing it gates is one unrelated lazy-file-load log line.

**`FS.syncfs` must never be called twice concurrently, and nothing in
Emscripten enforces that.** `IDBFS.syncfs`'s own implementation
(`src/lib/libidbfs.js`) has no re-entrancy guard: two overlapping calls race
the same IndexedDB reconcile, and a callback can simply never fire — which
reads as the page hanging, not erroring. RPG Maker MV/MZ's `localStorage`
shim calls `js_write_file` once per key it persists (`mruby-mvjs/src/
mvjs.cxx`), so a single in-game "save" can close `save/websave.json` several
times in quick succession; the original 500ms debounce alone was not enough
to rule this out, since a slow flush (a large save, a loaded IndexedDB
origin) can still be in flight when the next debounce elapses and starts a
second one. Found the same way as the `FS_DEBUG` gap: by hand, on the
Cloudflare preview, this time as an actual hang while saving in MV/MZ. Fixed
by routing every `syncfs` call in `src/shell.html` — the initial populate and
every later flush — through one `runSyncfs` queue that keeps at most one call
in flight and coalesces anything requested while it runs into a single
follow-up call, rather than starting a second one concurrently.

**Staging a save file must not read it back through `/game`, or the mirror
hook triggers itself.** The first fix above still left a second, distinct
hang: `mirrorSave`'s own staging step read the just-closed file back with
`FS.readFile('/game/' + rel)` to copy its bytes into `/persist/<slug>/`, but
that read closes the file too, and closing a save-shaped path under `/game`
is exactly what `onCloseFile` is watching for — so the read re-fired
`mirrorSave` on itself. Because `persistReady` is already resolved by the
time any real save happens, each recursive call chains a new
already-resolved-promise microtask immediately rather than waiting on
anything, so the recursion never bottomed out: the microtask queue never
drained, and the tab froze solid on every single save, indistinguishable
from the `syncfs` re-entrancy hang above except that it reproduced on the
*first* save rather than only on a rapid burst of them. Fixed with a
`mirroring` re-entrancy flag around that read/write, mirroring (no pun
intended) the `restoring` flag `restoreSaves()` already used to keep its own
writes into `/game` from re-triggering the hook.

Before a project starts (`mountAndStart`/`startBundledSample` in
`src/shell.html`, right after the fresh assets are written and before
`rpg_start_game()`), whatever is under `/persist/<slug>/` is copied back onto
the matching `/game/...` path, restoring the previous session's saves ahead
of the title screen's Continue check.

## Consequences

- Saves now survive a reload or closed tab, for every maker this build
  supports, with zero changes to `src/main.cxx`, the RGSS/LCF mruby
  gems, or `mruby-mvjs/src/mvjs.cxx` — the persistence layer only ever reads
  and writes bytes the existing save code already produced.
- The project-slug key is a sanitized copy of the loaded zip's URL/repo text
  or local filename, not a real per-project identifier. Two different
  projects that happen to share a bare filename (e.g. two different local
  `game.zip` uploads) will collide and overwrite each other's saves. A
  content hash or an explicit project id is a natural follow-up if this
  proves to matter in practice.
- The save-shape patterns are inferred from each maker's *stock* save
  filenames. A game whose own custom script renames its save files (rare,
  but not impossible for RGSS games — the save path is just Ruby string
  literals in an editable script) would not be recognized and would fall
  back to the pre-existing behavior: it still runs, it just does not
  persist across reloads.
- `FS.syncfs` is asynchronous and IndexedDB writes are not instantaneous; a
  tab closed within the 500ms debounce window (or while a sync is still
  in flight) can still lose the very last write. The `pagehide` handler
  gives the in-flight write a head start but cannot guarantee it lands
  before the page actually unloads — no synchronous IndexedDB API exists to
  close that gap from the main thread.
- No UI was added to inspect or clear persisted saves (unlike the existing
  *Clear cached archives* control for the separate zip cache); doing so is
  additive, scoped-out follow-up work rather than something this change
  needed.
- **No automated check exercises the actual browser runtime behavior.** CI's
  `wasm` job proves the page builds and links (which would not have caught
  the missing `FS_DEBUG` setting above — that is a purely runtime gap, not a
  build error); nothing here drives a real page in a browser and confirms a
  save round-trips through a reload the way the manual Cloudflare-preview
  check that found the `FS_DEBUG` gap did. A headless-browser smoke test
  (Playwright driving the deployed/preview page, or a served local build)
  covering "write a save, reload, save is still there" is a natural
  follow-up so a regression here is caught by CI rather than by hand again.
- This is the local-persistence half of syncing save data to a remote
  service (e.g. Google Drive, mirroring what a Chrome extension's
  `chrome.storage`/`chrome.identity` could do): a cloud sync layer needs
  exactly the durable, per-project save bytes this change now keeps in
  `/persist/<slug>/` to upload, and can hook the same `mirrorSave`/
  `restoreSaves` points in `src/shell.html` rather than re-deriving which
  files are saves from scratch.
