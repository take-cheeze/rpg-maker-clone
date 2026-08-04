- CI's `wasm` job now fetches/builds the MV sample engine as a `background: true`
  step, so the corescript clone overlaps the emcc/ccache cache restores and the
  `emcmake cmake` configure instead of running strictly before them. A
  `wait: [mv-sample]` barrier before the build keeps the guarantee the inline
  step gave: `WASM_SAMPLE_DIR` is consumed at link time (as an emcc
  `--preload-file` that generates `index.data`), so the engine files are always
  in place before linking, and a failed fetch still fails the job.
