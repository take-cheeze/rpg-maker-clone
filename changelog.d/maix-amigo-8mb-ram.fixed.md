- **Maix Amigo usable RAM**: the K210 linker script only ever described the
  6MB "general purpose" SRAM bank as heap-backing memory. The chip's other
  2MB SRAM bank (meant for the KPU neural-net accelerator's weights, sitting
  physically contiguous right after the 6MB bank) was sitting idle since
  none of this port's firmwares touch the KPU.
  `app/maix/patch_kendryte_ram_size.py` extends the linker's `ram` region
  to cover both, folding that 2MB in as ordinary heap for
  `maix_rgss_boot`/`maix_game`/`maix_game_sd`. Confirmed on real hardware:
  `get_free_heap_size()` grew by exactly 2MB at runtime, no crash, no
  change in behavior otherwise. Found while investigating a real-game
  (large `RPG_RT.ldb`) SD-boot memory-pressure hypothesis -- it didn't turn
  out to be the fix for that specific hang (see `app/maix/README.md`), but
  the extra headroom is real and free, so it ships regardless.
