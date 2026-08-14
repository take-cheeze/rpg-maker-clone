- CI's `labeler.yml` `label` job now runs on the `ubuntu-slim` runner instead
  of `ubuntu-24.04`. It only runs the `actions/labeler` action — no checkout,
  no build tooling — so the small image (1 CPU, 5 GB RAM, 15-minute cap)
  covers it at a lower rate, the same reasoning as `preview-gate` in
  `build.yml`. `labels.yml`'s `sync` job and `issue-labels.yml`'s `label` job
  were tried on `ubuntu-slim` too but reverted to `ubuntu-24.04`: both run a
  Ruby script, and the slim image doesn't ship a Ruby interpreter (only `gh`
  and `jq` are preinstalled there), which failed a real run with "ruby:
  command not found".
