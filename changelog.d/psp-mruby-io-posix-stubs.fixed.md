- **The PSP EBOOT now links libmruby.a.** mruby-io's default I/O HAL
  (hal-posix-io, auto-selected since nothing in `build_config.rb` picks one
  explicitly) calls six POSIX functions pspdev's newlib declares but does
  not implement -- `dup`/`dup2`/`sysconf` back its subprocess-spawn support,
  `ftruncate`/`flock`/`dup` back `IO#dup`/`File#flock`/`File#truncate` --
  which failed the final link with six "undefined reference" errors. None of
  that is reachable from this bring-up (no process model on the PSP, no game
  code yet), so `mruby-rgss/src/psp_io_stubs.c` (`PSP_BUILD`-gated, like the
  rest of the PSP HAL) now supplies minimal set-errno-and-fail definitions
  instead.
