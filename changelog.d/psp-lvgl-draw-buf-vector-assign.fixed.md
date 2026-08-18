- **The PSP EBOOT no longer crashes inside `psp_display_create` on a null
  LVGL draw buffer.** `std::vector<uint8_t>::assign(n, 0)`, called there to
  size-and-zero the two LVGL partial-render draw buffers on first use, is
  broken on this pspdev g++/libstdc++ build specifically when growing an
  empty (0-capacity) vector: it allocates the buffer correctly but leaves the
  vector's own begin pointer null while its end pointer holds the real
  allocated address, so `.data()` comes back null and `.size()` comes back as
  that allocated pointer's raw integer value reinterpreted as a count.
  Confirmed in isolation against the same toolchain: `vector(n, 0)`'s
  constructor and `vector::resize(n)` do not share the bug, only `assign()`
  does. `lv_display_set_buffers` then either tripped its own `buf1 != NULL`
  assert on the null pointer, or -- on binary layouts where the timing
  differs enough that the bad pointer isn't exactly null -- handed LVGL and
  later `flush_cb` calls a wild pointer to write display pixels through,
  corrupting unrelated memory including LVGL's own TLSF allocator pool. That
  corruption is what the "block already marked as free" assert deeper in
  `docs/adr/0047-psp-memory-budget.md`'s P1 trail (bug 7) traced back to.
  Fixed by switching both buffers to `.resize(n)`, which zero-initializes the
  same way and does not hit the bug. With this fixed, the EBOOT now boots
  past display creation and into `mrb_open`'s GC init before hitting a new,
  separate, not-yet-diagnosed crash (a near-null write inside `mrb_gc_init`);
  see the ADR for the full trail.
