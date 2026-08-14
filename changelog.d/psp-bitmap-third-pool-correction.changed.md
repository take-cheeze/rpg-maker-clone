- **PSP memory-budget ADR: corrected the bitmap/image-cache finding.**
  `docs/adr/0047-psp-memory-budget.md`'s Finding 3 previously described
  decoded RGSS bitmaps as an LVGL image-cache sizing problem. Checked
  directly against `mruby-rgss/src/lib.cxx`: `Bitmap::buffer` is a plain
  `std::vector<uint8_t>` handed to LVGL's canvas widget as an
  externally-owned pointer (`lv_canvas_set_buffer`) — there is no LVGL image
  cache in play, and decoded bitmap pixels never touch `LV_MEM_SIZE` at all.
  They live in the plain C runtime heap (newlib `malloc` on the PSP), a
  third pool alongside LVGL's pool and mruby's object graph, currently with
  no cap of its own. P4 is rewritten accordingly: nothing to implement that
  the bring-up EBOOT's existing memory-reporting heartbeat doesn't already
  cover once the interpreter is linked.
