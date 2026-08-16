- The `psp-smoke` CI job now runs the EBOOT under the PPSSPP that nixpkgs
  ships (`packages.ppsspp` in `flake.nix`, pinned by `flake.lock` and
  substituted prebuilt from `cache.nixos.org`) instead of cloning and compiling
  the emulator itself. The apt build-deps step, the source build and the
  hand-rolled `ppsspp-<tag>` tree cache are gone, along with the `cd` into that
  tree — the packaged binary resolves its own `assets/`, so the smoke test runs
  it from anywhere as `./ppsspp/bin/ppsspp-headless`. Same flags, same markers;
  the job stays non-blocking.
