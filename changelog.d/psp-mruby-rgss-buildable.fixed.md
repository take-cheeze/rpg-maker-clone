- **`mruby-rgss` now actually cross-compiles for the PSP.** The `psp` mruby
  cross-build (`build_config.rb`) had never pulled `mruby-rgss` in before, so
  three blockers went uncaught by CI until the interpreter-linking slice
  started exercising it directly:
  - `mruby-rgss/src/terminal.cxx` (the sixel/iTerm2 terminal backends) used
    POSIX `termios.h`/`sys/ioctl.h` and a `std::thread` writer unconditionally
    at file scope, unlike `psp.cxx`/`wio.cxx`'s self-guarded pattern. Now
    guarded the same way, compiling out entirely on `PSP_BUILD`/
    `WIO_TERMINAL` with a stub for the one symbol (`rgss_terminal_poll`)
    called unconditionally elsewhere in the gem.
  - `mrbgem.rake` unconditionally linked `pthread`, needed only by that same
    writer thread. Now conditional on the build's own name (`psp`/`wio`),
    not on `MRUBY_TARGET` (which is also set while the native host build —
    still needing pthread, to produce `mrbc` — runs in the same
    cross-compile session).
  - `mruby-mvjs` (RPG Maker MV/MZ via embedded QuickJS) links against `qjs`
    and optionally EGL/GLESv2, neither buildable for MIPS/pspdev right now.
    Never in scope for the PSP port, so `rpg_maker_gems` gained an
    `include_mvjs:` switch and the `psp` cross-build passes `false`.
  See `app/psp/README.md`'s "Not yet wired" section for what's still ahead.
