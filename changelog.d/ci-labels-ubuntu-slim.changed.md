- CI's label-management jobs (`labeler.yml`'s `label`, `labels.yml`'s `sync`,
  and `issue-labels.yml`'s `label`) now run on the `ubuntu-slim` runner
  instead of `ubuntu-24.04`. None of them need build tooling, so the small
  image (1 CPU, 5 GB RAM, 15-minute cap) covers them at a lower rate, the
  same reasoning as `preview-gate` in `build.yml`. The image only preinstalls
  `gh` and `jq`, not a Ruby interpreter (confirmed by a real run of `sync`
  failing with "ruby: command not found"), so the two jobs that run a Ruby
  script (`labels.yml`'s `sync`, `issue-labels.yml`'s `label`) install one
  with `ruby/setup-ruby` before their script step.
