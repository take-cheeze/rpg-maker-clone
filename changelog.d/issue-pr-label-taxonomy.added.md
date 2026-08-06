- Issues and pull requests now carry a **label taxonomy**: `engine:` (2000,
  2003, XP, VX, VX Ace, MV, MZ), `platform:` (wasm, terminal, linux, windows,
  psp, wio, other), `component:` (graphics, audio, input, the mruby and JS
  runtimes, data, save, events, scenes, battle, build, ci, docs, tooling),
  `type:` and `status:`. `.github/labels.yml` is the source of truth and is
  applied by `scripts/sync_github_labels.rb`; pull requests are labelled from
  their changed paths, and the new issue forms map their Engine / Platform /
  Component pickers to the same labels. `scripts/label_config_check.rb` (run
  from pre-commit) keeps the three configs in agreement. See `docs/labels.md`.
