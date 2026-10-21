- **CI: a failed `nix build` in the flake job no longer passes.** The
  "Build flake" step ran under `bash -e`, which does not set `pipefail`, so the
  pipeline took the filter's exit status and reported success. The step now
  sets `pipefail` itself. The output filter also keeps lines that contain
  invalid UTF-8 bytes, which were replaced by `binary file matches` before.
