- **CI** gives the `deploy-pages` and `preview-cloudflare` jobs a 10-minute
  timeout. A publish that stalls GitHub-side before its first step (its
  `github-pages` concurrency slot or its environment deployment) queued every
  later deploy behind it indefinitely: publishing was silenced from 2026-10-05
  until the stuck job was cancelled by hand on 2026-11-01. Both jobs need
  seconds, so the timeout fires only on a stall.
