- **CI: stop invoking `nix develop -c <cmd>` on every step.** The `build`,
  `ruby-checks` and `wasm` jobs each called `./scripts/nix-develop.bash` ~25
  times, re-evaluating the flake and racing every other `nix` process for the
  Nix store's SQLite lock on each call (there is no nix-daemon in CI's
  single-user install, hence `scripts/nix-develop.bash`'s SQLite-busy retry).
  Each job now runs new `scripts/nix-develop-export-env.bash` once, which
  realises the dev shell for real and exports its environment into
  `$GITHUB_ENV` / `$GITHUB_PATH` in the same step, so every later step —
  including the `background: true` downloads and smoke tests — runs its
  command directly with no further `nix` invocation and no store-lock
  contention. `flake.nix` also gained a `devShells.default` output alongside
  the legacy `devShell` (the modern flake schema spelling). The old
  `scripts/nix-develop.bash` wrapper is no longer used by CI, but stays for
  local use (`.github/ISSUE_TEMPLATE/bug_report.yml` points contributors at
  it for running the built binary inside the dev shell).
