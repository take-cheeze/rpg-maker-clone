- **`scripts/build_psp_fixup_imports.bash` now installs into `$PSPDEV`, and the
  PSP CMake configure refuses to build against the stock tool.** The script
  hardcoded `/usr/local/pspdev/bin/psp-fixup-imports` — the path inside the
  `pspdev/pspdev` container the `psp` CI job uses. Against a natively installed
  pspdev it therefore wrote the patched tool somewhere nothing reads, reported
  success, and left the toolchain's own stock `psp-fixup-imports` in place, so
  the resulting EBOOT carried exactly the misordered imports
  `patches/psp-fixup-imports-jal-relocation-aware.patch` exists to prevent:
  `SysMemUserForUser`'s stub table overlapped `ThreadManForUser`'s, leaving
  `sceKernelAllocPartitionMemory`/`sceKernelGetBlockHeadAddr` unbound, so
  `_sbrk` never obtained a heap, the first real `malloc()` never returned, and
  `user_main` deadlocked under PPSSPP-headless after printing `RPG2K_PSP_BOOT`.
  The default is now `$PSPDEV/bin/psp-fixup-imports` — the same variable
  pspdev's own `CreatePBP.cmake` resolves the tool through — falling back to
  `/usr/local/pspdev` when `$PSPDEV` is unset; `pspdev/pspdev:latest` exports
  `PSPDEV=/usr/local/pspdev`, so the `psp` CI job resolves the path it always
  did. `app/psp/CMakeLists.txt` additionally fails configure outright when the
  installed tool lacks the patch, detected by a format string only the patched
  build carries, and re-runs the check whenever the tool is replaced.
