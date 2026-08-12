# 43. CI's own downloads can use the CORS proxy cache

Date: 2026-08-12

## Status

Accepted

## Context

[ADR 42](0042-cors-proxy-r2-cache.md) gave the CORS proxy an R2 cache for the
web loader's benefit. CI has the same shape of problem, independently: `build`
and `wasm` (`.github/workflows/build.yml`) fetch a handful of test-bed
archives and assets straight from their origin host on every run —
`scripts/download-nepheshel.bash` (`til.sakura.ne.jp`),
`download-prayforyou.bash` (`dl.fgamearchives.com`), `download-freepats.bash`
(the npm registry, checksum-pinned), and `download-default-font.bash`
(`raw.githubusercontent.com`, commit-pinned). Two of those are small
third-party hosts with no CDN behind them — exactly the kind of host that
either rate-limits or occasionally falls over under CI-scale traffic.

This is already mitigated once: a `cache test game` `actions/cache` step
(keyed on the download scripts and generated sample content) restores
previously-fetched files before any download script runs, and each script
already skips its own work when the file is on disk. So on the common path —
an unchanged cache key — none of this network traffic happens at all. The gap
is the fallback path: a new runner, an evicted cache (Actions caches are
capped at 10 GB/repo and evicted after 7 days unused), or a changed download
script all invalidate that key, and CI falls straight back to hitting the
origin host cold. That's the case the R2 cache built for the loader can also
absorb — for free, since the infrastructure already exists.

Not every download script is eligible. `download-mtf-meido-action.bash`,
`download-opengame-xp.bash`, and `download-lunatic-core.bash` use `git clone
--depth 1 --sparse` against GitHub, not a plain URL fetch — the Worker proxies
a single `GET`, not the git smart-HTTP protocol, and sparse checkout's whole
point is to avoid pulling files the proxy can't see into either. RTP
(`rtp_install.bash` / `rtp_xp_install.bash`) is left alone too: it already has
its own `actions/cache` entry, and its host (`cdn.tkool.jp`, the maker's own
CDN) isn't the small-hoster case this is aimed at.

## Decision

`scripts/cors-proxy-url.bash` — sourced by the four eligible download
scripts — adds `proxied_url <url>`, which rewrites a URL through
`$CORS_PROXY_URL` when set, building the identical two prefix shapes the web
loader itself builds (query-style `?url=`, path-style `/<raw>`; see ADR 10).
Unset (the default, including on every fork), it returns the URL unchanged —
this is opt-in the same way `ARCHIVE_CACHE`/`ALLOWED_HOSTS`/etc. are opt-in on
the Worker side.

`build.yml` sets `CORS_PROXY_URL: ${{ secrets.CORS_PROXY_URL }}` as a
job-level env on `build` and `wasm`. A **secret**, deliberately, not a
repository **variable**: every download script runs under `set -eux`, so the
resolved URL — proxy prefix and all — lands verbatim in the step's trace
output, and a value the workflow carries as `${{ secrets.CORS_PROXY_URL }}`
is what makes GitHub register it for automatic log masking. A prefix with a
baked-in `AUTH_KEY` (docs/cors-proxy.md) landing unmasked in a public
Actions log would defeat the point of having a key at all.

## Consequences

- No behavior change on the common path: with `CORS_PROXY_URL` unset (every
  fork, and this repo unless someone deploys a proxy and sets the secret),
  every download script does exactly what it did before this change.
- Where it does apply, it only ever fires on an `actions/cache` miss — most
  runs never touch `proxied_url` at all, so this is a fallback layered under
  the existing cache, not a replacement for it.
- `ALLOWED_ORIGINS`, if the proxy owner sets it, silently breaks this: `wget`
  and `curl` send no `Origin` header, so an origin-restricted proxy 403s every
  CI request no matter what `CORS_PROXY_URL` is. Documented in
  `docs/cors-proxy.md` as a control that isn't compatible with CI use;
  `AUTH_KEY` and `ALLOWED_HOSTS` are.
- The three git-clone-based downloads and the RTP installers are unchanged —
  proxying them would need a different mechanism (a git proxy, or switching
  them to codeload zip downloads and giving up sparse checkout), not a
  follow-up to this ADR.
