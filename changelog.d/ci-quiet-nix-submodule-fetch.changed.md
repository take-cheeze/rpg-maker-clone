- **CI: drop the ~20k-line git ref dump nix prints before every build.** Because
  `flake.nix` sets `self.submodules = true`, each `nix develop` / `nix build`
  hands every submodule to nix's git fetcher, which hardcodes `allRefs = true`
  and so fetches `refs/*:refs/*` — including the `refs/pull/*` heads GitHub
  keeps for every pull request ever opened on mruby, lvgl and friends. The first
  nix command of a job printed a `* [new ref]` line for each of them, burying
  the rest of the log. Nix's own `--quiet` cannot reach it: the fetch is the
  `git` binary itself, run with `--progress` and holding nix's stderr directly
  rather than logging through it. New `scripts/drop-git-fetch-noise.bash` filters
  the ref table, the object counters that forced `--progress` brings with it and
  the clone/submodule bookkeeping out of `scripts/nix-develop.bash` and the
  flake job's `nix build -L` — including the clones the download scripts run
  inside the dev shell. `From <url>`, server-side `remote:` messages, rejected
  refs and any fetch failure stay visible.
