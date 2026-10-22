- The two Unicode mapping tables (`bestfit932.txt`, `JIS0208.TXT`) are now
  vendored under `data/unicode-mappings/` instead of being downloaded at build
  time. The Nix flake, the native and PSP build scripts and the CI jobs copy
  them from there and still check them against the same sha256 pins.
