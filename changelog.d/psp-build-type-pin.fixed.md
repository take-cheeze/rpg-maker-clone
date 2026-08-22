- **The PSP EBOOT's optimisation level is now pinned instead of inherited from
  the environment.** Nothing set `CMAKE_BUILD_TYPE`, and CMake initialises it
  from the environment variable of the same name — which this repo's nix
  devshell exports as `RelWithDebInfo`. A local build inside `nix develop`
  therefore compiled at `-O2 -g -DNDEBUG` while the `psp` CI job, running in a
  bare pspdev container, got an empty build type and no optimisation flags at
  all: two undeclared, different builds of the same commit. That matters
  because the `-O2` build is broken — it halts on LVGL's TLSF assert
  (`!block_is_free(block)` in `lv_tlsf_realloc`) during `lv_init()`, while the
  unoptimised build boots to completion; confirmed by building in the *same*
  container both ways, so only the flag differs. Pinned to `Debug` through a
  `RPG2K_PSP_BUILD_TYPE` cache variable, so an explicit override stays possible
  while the ambient one is ignored. Provisional: `MinSizeRel` is the better
  long-term answer for a target whose whole image is RAM-resident, once the
  `-O2` failure is root-caused. `app/psp/README.md` records what that
  investigation has already eliminated (the draw buffers, strict aliasing,
  `lv_tlsf.c` alone, `psp_unwind_fde.cxx`, and PPSSPP's sysclib return values).
