# 31. MIDI patches in their own split data packages

Date: 2026-08-06

## Status

Accepted

Amends [26. Downloaded FreePats patch set for MIDI
playback](0026-bundled-freepats-midi-patches.md), whose browser build mounted
the patches through `--preload-file`.

## Context

ADR 0026 gave the browser build its instruments by adding
`--preload-file=assets/timidity@/timidity` to the link. emcc packs every
`--preload-file` into one `index.data`, so with the MV sample and the default UI
font alongside them the page shipped a single 35.8 MiB file, ~31.8 MiB of it
FreePats.

**Cloudflare Pages refuses any file over 25 MiB.** That is where `/preview`
deploys, so from the moment the patches landed every preview deployment failed:

```
✘ [ERROR] Error: Pages only supports files up to 25 MiB in size
  index.data is 35.8 MiB in size
```

Nothing else noticed. The build succeeded, `index.data` loaded fine locally, and
GitHub Pages allows 100 MiB per file so the published page was unaffected and
played MIDI. Only PR previews were broken, and only for whoever ran `/preview`.
The same limit had already bitten `index.wasm` once (ADR 0026 records
`-gseparate-dwarf` being added to keep DWARF out of it), which is what makes the
repeat worth writing down: the ceiling applies to *every* published file, and
each new bundled asset is another chance to cross it.

Options:

- **Compress the preload** (`-sLZ4=1`). GUS `.pat` is raw PCM sample data and
  compresses poorly; the estimate lands around 28–32 MiB, still over, and the
  build would be one FreePats revision away from failing again.
- **Downsample the patch set for the web.** A dependable size win, but it trades
  audio quality for a CDN constraint and adds a resampling step to the asset
  pipeline.
- **Drop the patches from preview builds.** Makes previews deploy, and makes
  them useless for reviewing anything about audio.
- **Package the patches separately, split to fit.** Keeps the full set at full
  quality, costs an extra script tag and a build step.

## Decision

Package the patch set outside `index.data`, split across as many files as the
size budget requires, with **`scripts/pack-timidity-data.py`**.

It drives the same `tools/file_packager.py` that `--preload-file` uses
internally, bin-packing the patches largest-first into `timidity0.data`,
`timidity1.data`, … under a 16 MiB budget — well beneath the 25 MiB ceiling, so
a patch set that grows costs another package rather than creeping up on the
limit. The per-package loaders `file_packager` emits are concatenated into one
`timidity.js`, which `src/shell.html` pulls in ahead of the runtime script.

- **Load ordering is what makes it correct.** Each loader registers an
  Emscripten run dependency against the `Module` the shell defines above it, so
  `main()` does not start until every package has unpacked. TiMidity never sees
  the seam: the packages write into one MEMFS tree under `/timidity`, and it
  resolves patches through its own search path at song-load time, long after
  they have all landed.
- **The split carries no meaning.** Grouping is by size alone; the only
  invariant is that no file exceeds the budget. Re-running after the patch set
  changes re-balances it, and neither the page nor the synthesiser cares how
  many packages result. A verified 44-voice MIDI drawing instruments from both
  packages plays identically to the single-package build.
- **`timidity.js` is always generated**, even with `-DWASM_MIDI_PATCHES=OFF`,
  where it is a comment saying so. The shell's script tag therefore stays
  unconditional instead of 404ing on a deliberately slim page, and the engine
  reports the silence itself (ADR 0026).
- **CI asserts the ceiling directly**, over exactly the files the deploy jobs
  publish, rather than trusting the split to have worked. The patch-set presence
  check moves from `index.js` to `timidity.js` with it.

## Consequences

- **`/preview` deploys again.** The largest published file drops from 35.8 MiB
  to ~16 MiB, and `index.data` is left holding only the MV sample and the font.
- **The failure mode is now loud.** A future asset that crosses 25 MiB fails the
  `wasm` job with the offending filename and its size, instead of succeeding
  everywhere except a preview deploy nobody runs on every PR.
- **One more request on page load**, same total bytes. The packages are static
  and cache normally.
- **The page has a build-time dependency on Python 3** (already in the dev
  shell, and already used by `scripts/serve.py` and the sample generators) and
  on `file_packager.py`'s location inside the Emscripten sysroot. The latter is
  the one real coupling: it is a tool emcc itself invokes, so it is stable, but
  it is not a documented public interface and an Emscripten reorganisation would
  break the build rather than silently degrade it.
- **Publishing the page now means publishing `timidity.js` and
  `timidity*.data` too.** Dropping them from a deploy would not fail anything —
  it would quietly ship a page whose `.mid` BGM is silent, which is exactly the
  shape of bug ADR 0026 kept running into. The artifact list says so where the
  paths are listed.
- Deliberately **not** applied to `WASM_SAMPLE_DIR` or the UI font: both are
  small enough that folding them into `index.data` is simpler, and splitting
  them would buy nothing today.
