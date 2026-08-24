- **PSP:** the EBOOT failed to link ("undefined reference to `chroot`") once
  `mruby-dir` joined the shared gem set and its `hal-posix-dir` object got
  pulled into the link — upstream mruby's `mrb_hal_dir_chroot` gates the
  no-`chroot` platforms on `__ANDROID__`/`__MSDOS__` but not `__PSP__`.
  `app/psp/psp_missing_syscalls.c` provides the same ENOSYS answer the gate
  gives those platforms, until the upstream gate learns `__PSP__`.
