- **The `clang-format` pre-commit hook now installs its own clang-format from
  PyPI** (`clang-format==22.1.8`) instead of running whatever binary is on
  PATH, and the Nix dev shell drops `clang-tools` accordingly. Everyone
  formats with the same version — CI, a local `nix develop`, and the plain
  container `scripts/native-build-without-nix.bash` targets — so the version
  difference that made clang-format 18 flag three pre-existing lines in
  `mruby-rgss/src/lib.cxx` no longer applies. Check a file locally with
  `pre-commit run clang-format --files <file>`.
