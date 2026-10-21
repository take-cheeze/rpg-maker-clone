- **CI: the `flake` job no longer fails intermittently on an uninitialised
  `3rd/SDL`.** It skipped `3rd/SDL`, `3rd/SDL_mixer` and `3rd/optcarrot` when
  initialising submodules, but its `nix build '.?submodules=1'` walks every
  `.gitmodules` entry and failed on the empty `3rd/SDL` directory. It now
  initialises all submodules.
