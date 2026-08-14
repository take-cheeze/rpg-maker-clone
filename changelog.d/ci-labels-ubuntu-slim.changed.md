- CI's label-management jobs (`labeler.yml`'s `label`, `labels.yml`'s `sync`,
  and `issue-labels.yml`'s `label`) now run on the `ubuntu-slim` runner
  instead of `ubuntu-24.04`. None of them need build tooling — just a
  checkout (or none, for `labeler.yml`) and a script driving `gh` — so the
  small image (1 CPU, 5 GB RAM, 15-minute cap) covers them at a lower rate,
  the same reasoning as `preview-gate` in `build.yml`.
