- **CI: stop invoking `nix develop -c <cmd>` on every step.** The `build`,
  `ruby-checks` and `wasm` jobs each called `./scripts/nix-develop.bash` ~25
  times, re-evaluating the flake and racing every other `nix` process for the
  Nix store's SQLite lock on each call (there is no nix-daemon in CI's
  single-user install, hence `scripts/nix-develop.bash`'s SQLite-busy retry).
  Each job now realises the dev shell once (the existing warm-up step) and
  then runs new `scripts/nix-develop-export-env.bash` to export its
  environment into `$GITHUB_ENV` / `$GITHUB_PATH`, so every later step —
  including the `background: true` downloads and smoke tests — runs its
  command directly with no further `nix` invocation and no store-lock
  contention. `flake.nix` also gained a `devShells.default` output alongside
  the legacy `devShell` (the modern flake schema spelling).
