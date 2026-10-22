- CI now caches the pinned FreePats MIDI patch tarball (`assets/.freepats`)
  in the `build` and `wasm` jobs. A cache hit skips the npm download, so a
  transient registry failure no longer fails those jobs.
