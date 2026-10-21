- **bc2cpp:** the native return analysis reads the closed world's sources with
  their presym IDs and the Onigmo header (`scripts/bc2cpp/analysis_headers.rb`,
  written by `closed_build.bash`). `to_s` is now proven String across the closed
  world's native owners.
