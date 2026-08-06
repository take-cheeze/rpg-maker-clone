- **`/preview` deploys the browser page again.** The MIDI patch set went into
  the page through `--preload-file`, which folds every preloaded asset into one
  `index.data` — 35.8 MiB of it with the MV sample and the UI font alongside.
  Cloudflare Pages, where `/preview` publishes, refuses any file over 25 MiB, so
  every preview deployment had failed since the patches were added
  (*"Pages only supports files up to 25 MiB in size — index.data is 35.8 MiB"*).
  Nothing else noticed: the build passed, the page worked locally, and GitHub
  Pages allows 100 MiB per file, so the published site was fine.
- New `scripts/pack-timidity-data.py` packages the patches outside `index.data`,
  bin-packing them into `timidity0.data`, `timidity1.data`, … under a 16 MiB
  budget and emitting one `timidity.js` loader for however many packages that
  takes. `src/shell.html` loads it ahead of the runtime script, so the run
  dependencies each package registers are settled before `main()` — TiMidity
  sees one `/timidity` tree and never learns it arrived in pieces. The largest
  published file is now ~16 MiB. Verified in a browser: a 44-voice MIDI drawing
  instruments from both packages plays identically to the unsplit build. See
  ADR 0031.
- CI now checks that **no published file exceeds 25 MiB**, listing every one
  with its size, so the next asset that crosses the ceiling fails the `wasm` job
  by name instead of only breaking a preview deploy that not every PR runs.
