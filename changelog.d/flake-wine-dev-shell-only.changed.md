- `flake.nix` no longer puts wine in the *package*. `winePackages.staging` /
  `winePackages.fonts` moved from `packages.build.nativeBuildInputs` into
  `devShells.default`, so `nix build '.#build'` (the `flake` CI job) stops
  realising a 32-bit wine closure the sandboxed build never opens, while every
  consumer that actually needs wine — `nix develop`, and with it the `build` CI
  job's `scripts/rtp_install.bash` / `rtp_xp_install.bash` — is unchanged.
  `winetricks` is dropped outright: nothing in the tree has ever called it.
