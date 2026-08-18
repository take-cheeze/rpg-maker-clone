- **`app/psp/CMakeLists.txt` now links `pspuser` before `pspkernel`.** Both
  static libraries provide `sceKernelCreateCallback`, `sceKernelSleepThreadCB`,
  and `sceKernelMaxFreeMemSize` — as distinct `ForUser`/`ForKernel` NIDs, not a
  benign duplicate. With `pspkernel` first, `ld` kept its `ForKernel` stub for
  all three under `--allow-multiple-definition`'s first-definition-wins rule,
  so this user-mode EBOOT's imports named the kernel-mode NID for each.
  PPSSPP's loader has no HLE implementation registered under those modules for
  a plain homebrew EBOOT, so every call silently came back
  `SCE_KERNEL_ERROR_LIBRARY_NOT_YET_LINKED` — none of the three's callers
  (`setup_callbacks`'s `callback_thread`, and `_sbrk`'s heap-size probe in
  pspsdk's libcglue) check the return value. That's what was actually behind
  the PSP boot hanging under PPSSPP-headless past `RPG2K_PSP_BOOT`: `_sbrk()`
  re-ran its heap-init probe on every call forever, so the first real
  `malloc()` never returned. Linking `pspuser` first makes its correct
  `ForUser` definitions win instead — confirmed via PPSSPP's own syscall log:
  the "unknown syscall"/failed-LwMutex counts that used to run into the
  hundreds of thousands over a 15s boot attempt dropped to zero. Boot still
  doesn't complete — see `docs/adr/0047-psp-memory-budget.md`'s P1 section for
  the next blocker this uncovered — but this is a real, independent fix.
