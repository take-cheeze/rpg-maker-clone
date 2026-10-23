- The `bc2cpp-build` CI job runs `scripts/bc2cpp/sealed_host_check.rb`, which
  checks that `RPG2K_SEALED_HOST` means the same thing in the CMake option, the
  `--script` fence in `src/main.cxx`, and the closed-world guard that reads it.
