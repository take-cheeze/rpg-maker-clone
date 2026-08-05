- **MIDI plays in a browser page built the documented way.** The wasm build
  packaged the FreePats patch set only behind `-DWASM_MIDI_PATCHES=ON`, which
  defaulted to off and which the README's build snippet does not pass — so the
  page anyone built themselves had the TiMidity decoder and no instruments for
  it, and an RPG2000 project (whose BGM is nearly all `.mid`) ran completely
  silent. Not quietly, either: with no config to read, `Mix_LoadMUS` fails
  outright on a `.mid` (*"Couldn't open timidity.cfg"*), so the track never
  started. `WASM_MIDI_PATCHES` is now `AUTO`/`ON`/`OFF` and defaults to **AUTO**
  — the patches are packaged whenever `scripts/download-freepats.bash` has run,
  so fetch-then-configure is all it takes. `ON` still forces the preload for CI,
  where the download runs *alongside* the configure and a directory check would
  race it; `OFF` still gives a slim page.
- **The page now says when it cannot play MIDI**, instead of just going quiet.
  Its on-screen log mirrors stdout/stderr, and ng-log wrote only `ERROR` and
  above there, so every warning explaining a silent failure was invisible in the
  browser — it went to a log file in the in-memory filesystem that vanishes with
  the tab. The wasm build now mirrors warnings to the page log, the missing
  patch set reports the fix that applies in a browser (rebuild with the patches,
  not "set `TIMIDITY_CFG`"), and a `.mid` that fails to load because nothing can
  synthesise it says so rather than passing TiMidity's missing-file message
  through.
- CI now asserts that the published page actually carries the patch set, since
  losing it fails nothing at build time and only shows up as silence.
