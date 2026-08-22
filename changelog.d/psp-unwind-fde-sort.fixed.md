- **C++ exceptions now work in the PSP EBOOT, which unblocks booting past
  `mrb_open()`.** Any `throw` aborted inside libgcc's `uw_init_context_1`
  (`gcc_assert (code == _URC_NO_REASON)`), which fires when the unwinder cannot
  find an FDE for the frame it is unwinding. mruby is built with the C++
  exception ABI — automatic, since gems here ship `.cxx` sources — so
  `MRB_THROW` is a real throw and the first one during interpreter init killed
  the boot. The CFI was never the problem: `.eh_frame` is complete, correctly
  bracketed, inside a `PT_LOAD`, and registered before `main()`. The defect is
  libgcc's own `fde_radixsort`, an 8-bit-digit radix sort that needs four
  passes to cover a 32-bit address but whose output is exactly the state after
  two — the array it builds has 1460 inversions against the full `pc_begin` and
  zero against `pc_begin & 0xffff`, i.e. it is perfectly sorted on the low
  halfword. Since every code address in the EBOOT is `0x08xxxxxx`, that
  ordering is useless and the binary search in `search_object` misses every
  entry. Eliminated by measurement first: the CFI data, registration,
  `__builtin_return_address(0)`, libgcc's packed unaligned read in
  `unwind-pe.h`, and `memmove`/`memset` through the emulator's HLE.
  `app/psp/psp_unwind_fde.cxx` works around it by overriding
  `__register_frame_info`, `_Unwind_Find_FDE` and `__deregister_frame_info` and
  answering lookups from an index it builds and sorts itself; it reads each
  CIE's augmentation for the FDE pointer encoding and disables itself on any
  shape it does not recognise rather than guessing. With it the EBOOT reaches
  `RPG2K_PSP_MRUBY_OPEN ok` → `RPG2K_PSP_GAME_START` → a continuous
  `RPG2K_PSP_BRINGUP` heartbeat (5442 heartbeats, 544k frames, zero errors).
  Not yet upstreamed to pspdev, where the real fix belongs — the bug breaks C++
  exceptions for every PSP binary built with this toolchain.
