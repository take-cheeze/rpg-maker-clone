- **PSP bring-up EBOOT reports real memory numbers.** The `RPG2K_PSP_BRINGUP`
  heartbeat now carries `sceKernelTotalFreeMemSize`/`sceKernelMaxFreeMemSize`
  (the device's actual free RAM) and `lv_mem_monitor`'s current-use and
  `max_used` high-water mark for LVGL's own pool, once a second, into the same
  log CI's `psp-smoke` job already captures. This is ADR 0047's P1: real
  device measurements for the HAL's own footprint, ahead of the
  interpreter-linking slice that will need to size `LV_MEM_SIZE` for real. See
  `docs/adr/0047-psp-memory-budget.md`.
