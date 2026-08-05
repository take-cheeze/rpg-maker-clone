- The dev shell no longer pulls in `chromium`. It was there for one non-blocking
  smoke test that drove the emscripten page over the DevTools protocol, and it
  was the largest download in the shell — paid for by every `nix develop`, in
  every CI job, whether or not the job went near a browser. That check
  (`scripts/rpgxp_browser_check.py`) and its `wasm` CI steps are gone with it;
  the two page-only bugs it found stay fixed, and the native and wine XP checks
  are unchanged. See `docs/adr/0025-rpgxp-cross-runtime-testing.md` (amended).
