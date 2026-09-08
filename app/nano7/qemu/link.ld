/*
 * link.ld -- a flat, MMU-less image for QEMU's realview-pb-a8 machine, with
 * MEMORY regions sized against the ONE real NanoApps limit this app is
 * actually subject to -- not a blanket "give QEMU less RAM" guess.
 *
 * app/nano7/rpg2k_walk builds RAW_SURFACE := 1, which NanoApps' own
 * sdk/hb_app.mk turns into RELOC := 1: "the resident loads a .hbapp into an
 * operator-new arena" (hb_app.mk line 70), not the fixed BSS_VA/LINK_VA
 * scheme rpg2k_walk.c's own MAP_MAX_W/MAX_TILES comment cites -- that fixed
 * 0x09200000..0x09280000 gap is LV_SURFACE-specific (hb_app.mk's own
 * comment: parking .bss there is so a *compositor-coexisting* LVGL app
 * doesn't stomp the live OS's compositor heap; RAW_SURFACE apps don't do
 * that). So rpg2k_walk.c's existing ~512 KiB .bss heuristic is a
 * conservative guess carried over from a different app kind, not the real
 * enforced limit for this one, and ADR 61 says as much directly: for a
 * RELOC app, ".bss ... is free; only the code has to be tiny" -- the real,
 * empirically-tested ceiling (apps "hang or crash on launch" past it, per
 * ADR 61) is the ~500 KB PACKED .hbapp BLOB (.text + .rodata + the ABS32
 * reloc table mkrelocapp.py emits from them) NanoApps' loader uploads and
 * execs, not .bss at all.
 *
 * The regions below encode that distinction instead of erasing it:
 *   - `image`   caps .text+.rodata at 500 KiB, standing in for the real
 *               packed-.hbapp ceiling (this build doesn't run mkrelocapp.py,
 *               so .text+.rodata is the closest proxy for that blob size
 *               available here -- see scripts/nano7_qemu_build.bash).
 *   - `blobs`   the two exported map files, embedded as linked binary data
 *               (scripts/nano7_qemu_build.bash's objcopy step) because this
 *               target has no filesystem at all (docs/adr/0103). On real
 *               hardware these are read from disk at runtime and are NOT
 *               part of the uploaded blob, so they get their own region,
 *               generously sized against RW_MAP_HEADER_BYTES et al's own
 *               worst case (~115 KB for a full 128x128/255-tile export;
 *               see app/nano7/rpg2k_walk/rpg2k_walk.c) rather than counted
 *               against `image`.
 *   - `app_bss` rpg2k_walk.c's and rpg2k_walk_core.c's own static buffers
 *               (s_map_raw, s_tiles, s_cell, ...) -- kept at the app's
 *               existing ~512 KiB self-imposed budget (matching its own
 *               MAP_MAX_W/MAP_MAX_H/MAX_TILES sizing) even though ADR 61
 *               says a RELOC app's .bss isn't really capped there, simply
 *               because that is what the app was actually engineered
 *               against; this now enforces it at link time instead of
 *               leaving it as an unchecked comment.
 *   - `shadow_fb` app/nano7/shim_common/hb_fb_ops.c's framebuffer array --
 *               sized exactly to what a 240x432 XRGB8888 frame needs. This
 *               is NOT part of the app's own allocation on real hardware at
 *               all: hb_raw_surface.h's own comment says the resident
 *               "hands us the OS-composited framebuffer" -- system-owned
 *               memory outside anything the app links, which this region
 *               stands in for. Excluded from `app_bss` on purpose (see the
 *               per-object-file section rule below), or the harness's own
 *               framebuffer would be wrongly charged against a budget real
 *               hardware never charges it against.
 *   - `stack`   256 KiB, this harness's own choice, no real-hardware number
 *               behind it (a RELOC app's stack comes from wherever the
 *               resident's arena puts it, undocumented here).
 *
 * Total span from ORIGIN(image): 1,844,224 B (~1.76 MiB) -- what
 * scripts/nano7_qemu_run.bash's `-m` is sized against, in place of an
 * arbitrary 128 MiB that bore no relationship to any real limit.
 */
ENTRY(_start)

MEMORY {
  image     (rx) : ORIGIN = 0x70010000, LENGTH = 500K
  blobs     (r)  : ORIGIN = 0x7008d000, LENGTH = 128K
  app_bss   (w)  : ORIGIN = 0x700ad000, LENGTH = 512K
  shadow_fb (w)  : ORIGIN = 0x7012d000, LENGTH = 405K /* 240*432*4 = 414720 B, rounds up cleanly */
  stack     (w)  : ORIGIN = 0x70192400, LENGTH = 256K
}

SECTIONS {
  .text : { *(.text.boot) *(.text*) } > image
  .rodata : { *(.rodata*) } > image

  .data : { *(.data*) } > blobs

  /* Claimed first, so the general .bss rule below only sees what's left --
   * GNU ld places each input section into the first output section that
   * requests it and does not place it again. */
  .bss.shadow_fb (NOLOAD) : { *hb_fb_ops.o(.bss COMMON) } > shadow_fb
  .bss (NOLOAD) : { *(.bss) *(COMMON) } > app_bss

  _stack_top = ORIGIN(stack) + LENGTH(stack);

  /* Debug info isn't uploaded anywhere real; keep it out of every sized
   * region so it can't ever trip one of the LENGTH checks above. */
  .debug_frame 0 (INFO) : { *(.debug_frame) }
  .debug_line 0 (INFO) : { *(.debug_line) }
  .debug_line_str 0 (INFO) : { *(.debug_line_str) }
  .debug_info 0 (INFO) : { *(.debug_info) }
  .debug_abbrev 0 (INFO) : { *(.debug_abbrev) }
  .debug_aranges 0 (INFO) : { *(.debug_aranges) }
  .debug_str 0 (INFO) : { *(.debug_str) }
  .comment 0 (INFO) : { *(.comment) }
  .ARM.attributes 0 (INFO) : { *(.ARM.attributes) }
}
