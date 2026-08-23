- **Nix:** `packages.pspdev` packages upstream's pspdev release tarball
  (relocatable out of the box, `autoPatchelfHook`-wrapped, stock
  `psp-fixup-imports` replaced by the JAL-relocation-aware build compiled
  from the same pinned pspsdk commit the repo's patch targets), and a new
  `nix develop .#psp` devShell wires it up with the host tools mruby needs
  (cmake, ninja, ruby, bison, gperf) plus this flake's patched
  `ppsspp-headless` — a complete PSP build-and-run environment without the
  hand-installed `~/dev/pspdev`, verified end to end: configure, build and
  boot an EBOOT under PPSSPP from inside the shell.
