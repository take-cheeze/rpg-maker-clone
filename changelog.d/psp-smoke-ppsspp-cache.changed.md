- The `psp-smoke` CI job now caches the Nix store across runs. `flake.nix`'s
  `ppsspp` package carries a local patch (see
  `ppsspp-lwmutex-nix-patch.fixed.md`), so its output no longer matches
  nixpkgs' prebuilt closure on `cache.nixos.org` and every `nix build
  '.#ppsspp'` compiled PPSSPP from source — a multi-minute cost the job used
  to pay on every push. It now restores/saves that store with the same
  `cache-nix-action` step the rest of `.github/workflows/build.yml` already
  uses, keyed on `flake.*` plus the patch file itself (the patch changes
  PPSSPP's build without touching either flake file).
