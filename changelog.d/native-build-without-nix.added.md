- **`scripts/native-build-without-nix.bash`** builds and render-verifies the
  engine on a plain Debian/Ubuntu box, for an environment with a C++ toolchain
  but no Nix. It installs the SDL2 headers, initialises the `3rd/` submodules,
  puts `rake` where `/bin/sh` can find it (mruby builds itself with it) and
  fetches the two Unicode mapping tables the flake supplies through
  `$cp932_table` / `$jis0208_table` — verifying each against flake.nix's own
  sha256, so the build consumes the same bytes Nix would hand it. It then runs
  `--rgss_effect_probe` under Xvfb and both game boot checks. `docs/TODO.md` said
  the binary could not be built or run in an agent environment; it can.
