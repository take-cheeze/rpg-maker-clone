- **PSP:** removed `app/psp/psp_unwind_fde.cxx`, the override that answered
  `_Unwind_Find_FDE` from a self-sorted index because pspdev libgcc's
  `fde_radixsort` mis-sorted `.eh_frame`. The measurement predated the
  tail-call fixup fix (#1304) that left 49 mis-targeted calls in every
  EBOOT, so any observation of libgcc behaviour was confounded; with that
  fixed, stock libgcc passes every exception probe this port has and runs
  Nepheshel's New Game (raises and rescues included) for millions of frames
  — verified against both the native toolchain and CI's container build.
