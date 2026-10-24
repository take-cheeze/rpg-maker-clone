- **`bc2cpp-build`** no longer prints about a hundred
  `_FORTIFY_SOURCE requires compiling with optimization (-O)` warnings:
  `scripts/bc2cpp/closed_build.bash` drops Nix's `fortify` hardening for the
  `-O0` closed build's rake runs.
