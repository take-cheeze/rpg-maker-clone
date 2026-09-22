- The desktop Linux build now links `libstdc++`/`libgcc_s` statically
  (`-static-libgcc -static-libstdc++`), removing two Nix-store-path shared
  library dependencies from the executable's own link. SDL2/SDL2_mixer, GL and
  the OS audio backends stay dynamic; see
  [`docs/adr/0186-static-link-desktop-runtime.md`](docs/adr/0186-static-link-desktop-runtime.md)
  for why, and what a fuller static build would still need.
