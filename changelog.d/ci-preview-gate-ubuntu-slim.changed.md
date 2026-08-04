- CI's `preview-gate` job now runs on the `ubuntu-slim` runner instead of
  `ubuntu-latest`. The job only makes two `gh api` calls — resolve the pull
  request's head SHA and add the 👀 reaction — with no checkout and no build
  tooling, so the small image (1 CPU, 5 GB RAM, 15-minute cap) covers it and
  bills at a lower rate. `gh` and `jq` are preinstalled there.
