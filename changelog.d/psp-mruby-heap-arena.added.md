- **PSP: the mruby heap now lives in a bounded 8 MB arena (ADR 0047's P2).**
  `app/psp/main.cxx` overrides `mrb_basic_alloc_func` with a fixed-size,
  16-byte-aligned first-fit free-list allocator (with splitting and
  coalescing), so the interpreter can no longer grow unbounded across the
  PSP's ~24 MB and collide with the decoded-bitmap heap. Sharing LVGL's pool
  the way the desktop build does was not an option: LVGL's builtin TLSF pool
  only aligns to 4 bytes on 32-bit, which breaks mruby's word boxing. When
  the arena is exhausted the allocator returns NULL and mruby raises a
  catchable `NoMemoryError` instead of corrupting RAM. `app/psp/lv_conf.h`'s
  comment now states that its pool covers LVGL only. See
  `docs/adr/0047-psp-memory-budget.md`.
