- **Real ARM Cortex-A8 emulation for the iPod nano 7G walk app**
  (`app/nano7/qemu`, see ADR 103), complementing the host-side emulator
  (ADR 102) with a genuine CPU cost signal it couldn't give: this
  cross-compiles `app/nano7/rpg2k_walk/rpg2k_walk.c` with the real
  `arm-none-eabi-gcc -mcpu=cortex-a8` (the same compiler invocation
  NanoApps' own SDK uses) and boots it under `qemu-system-arm`'s `cortex-a8`
  core on the `realview-pb-a8` machine — a real PL110 display controller
  QEMU already ships (verified pixel-correct against a hand-drawn test
  pattern; no new peripheral code needed) and the Cortex-A8 PMU's real
  cycle counter, logged per frame over a real PL011 UART. No filesystem,
  SD card, or touch digitizer is modelled — the two exported map files are
  linked straight into the image instead. The new `nano7-qemu` CI job
  builds, boots, and pixel-checks a real exported map through it on every
  push. The framebuffer array and pixel primitives shared with the host
  build moved into `app/nano7/shim_common/hb_fb_ops.c` so both stay
  provably in sync. QEMU's RAM is sized (4 MiB, down from an arbitrary
  128 MiB) against linker `MEMORY` regions in `app/nano7/qemu/link.ld` that
  encode the one real NanoApps limit this app is actually subject to — the
  ~500 KB packed-`.hbapp` blob ceiling for a `RELOC` app (not the `.bss`
  gap `rpg2k_walk.c`'s own comment cites, which turns out to be a different
  app kind's limit) — so a future build that grows past it now fails to
  link instead of only failing on real hardware.
