- **PSP port (HAL bring-up).** A Sony PlayStation Portable backend, mirroring the
  Wio Terminal port's structure: a self-guarded (`PSP_BUILD`) LVGL display +
  input HAL in the `mruby-rgss` gem (`mruby-rgss/src/psp.cxx`, `include/psp.hxx`)
  that flushes to the `sceDisplay` framebuffer and scans the D-pad / analog stick
  / ✕○△□ via `sceCtrl`; a standalone pspdev CMake project under `app/psp/` that
  builds a bring-up `EBOOT.PBP` (display + input, no interpreter yet); a `psp`
  mruby MIPS cross-build in `build_config.rb` (`MRUBY_TARGET=psp`); an
  `rgss_psp_poll` input bridge wired into `Graphics.update`; and a `psp` CI job
  that compiles the EBOOT with the `pspdev/pspdev` container. See ADR 0010 and
  `app/psp/README.md`.
