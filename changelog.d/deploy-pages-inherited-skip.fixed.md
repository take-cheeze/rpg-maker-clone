- **The GitHub Pages deploy has been silently skipping since 2026-08-04**, so
  the published page has been stale for two days — every change merged in that
  window, the MIDI fixes included, is on `master` and not on the site.
  `deploy-pages` was not failing and its own condition was never wrong: it
  inherited a *skip*. A skipped job propagates down the entire `needs` chain,
  and moving the Cloudflare preview behind a `/preview` comment gave `wasm` a
  `needs: preview-gate` — a job that is skipped on every push. `wasm` overrode
  that for itself with `!cancelled()` and ran to success, but `deploy-pages`
  sits downstream of `wasm` and had no status-check function of its own, so the
  skip carried straight through it. Its `if` now starts with `!cancelled()`,
  which overrides the inherited skip, and states `needs.wasm.result == 'success'`
  explicitly, since that is the check `!cancelled()` gives up.
