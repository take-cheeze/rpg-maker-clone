- **`scripts/build_psp_docker.bash` builds the PSP EBOOT in the same
  `pspdev/pspdev` container CI uses**, instead of against a locally installed
  pspdev plus the Nix devshell. It mirrors the `psp` CI job step for step: same
  image, same apk packages, same hash-pinned Unicode mapping tables wired
  through `$cp932_table`/`$jis0208_table`, same `psp-cmake`/`cmake --build`.
  Output goes to `build-psp-docker/` by default rather than `build-psp/`, so a
  container build and a native build can sit side by side and be compared —
  which is how the two were found to differ: building `master` natively yields
  an EBOOT that halts on an LVGL TLSF assert under PPSSPP-headless, while the
  container build of the same commit does not. The PSP cross-toolchain is not
  the variable there (both `$PSPDEV/build.txt` manifests are byte-for-byte
  identical); what differs is the host half of the build.
