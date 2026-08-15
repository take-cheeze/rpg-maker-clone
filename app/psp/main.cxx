// PlayStation Portable EBOOT entry point -- hardware bring-up.
//
// This slice proves the HAL compiles and runs on the PSP and that libmruby.a
// (built for the psp target by build_config.rb, linked in via
// app/psp/CMakeLists.txt) actually links and boots on real MIPS/pspdev: it
// stands up the LVGL display (psp_display_create), scans the pad
// (psp_input_scan), draws a small status screen that echoes the pressed keys,
// and opens an mruby interpreter (mrb_open). main() owns the loop and pumps
// LVGL once per iteration -- the same "host owns the loop" shape the
// Emscripten and Wio builds use. Its per-second heartbeat also reports real
// free-memory and LVGL-pool numbers (see the RPG2K_PSP_BRINGUP marker below),
// which is ADR 0047's P1: measuring the HAL's own footprint on real
// hardware/an emulator ahead of sizing anything for a real game.
//
// mrb_open() here uses mruby's own default allocator (plain malloc) rather
// than routing through lv_malloc the way the desktop build does -- ADR 0047's
// P2 (share LVGL's pool vs. a separate arena) is still an open decision that
// this slice does not need to make just to prove the interpreter boots. No
// RGSS methods are registered and no game is started: the real RPG2k scene
// tree, Memory-Stick asset loading and the GAME_DIR convention are the next
// slice (see app/psp/README.md and docs/adr/0010-psp-port.md).

#include <cstdio>

#include <lvgl.h>
#include <mruby.h>
#include <pspiofilemgr.h>
#include <pspkernel.h>
#include <pspsysmem.h>

#include "psp.hxx"

// Standard pspsdk module metadata for a user-mode EBOOT. THREAD_ATTR_VFPU keeps
// the VFPU state saved across the main thread's context switches.
PSP_MODULE_INFO("rpg2k", 0, 1, 0);
PSP_MAIN_THREAD_ATTR(THREAD_ATTR_USER | THREAD_ATTR_VFPU);

namespace {

lv_obj_t* g_status_label = nullptr;

// Names for the RGSS key ids, indexed by PspKey, for the on-screen echo.
const char* const kKeyNames[PSP_INPUT_KEY_COUNT] = {
    "Up", "Down", "Left", "Right", "A", "B", "C"};

// Write a buffer to the PSP stdout (fd 1) and stderr (fd 2). Under an emulator
// the host captures these; on real hardware they go nowhere. The length is
// passed explicitly rather than derived with strlen: under PPSSPP pspsdk's libc
// string helpers resolve to firmware stubs (sysclib_strlen) that the emulator
// only partially implements, so a strlen-derived length can come back 0 and the
// write emits nothing. Both fds are written so whichever PPSSPP surfaces to its
// log is captured.
void psp_write(const char* s, int len) {
  sceIoWrite(1, s, len);
  sceIoWrite(2, s, len);
}

// The HOME-button exit callback, so the EBOOT quits cleanly back to the XMB.
int exit_callback(int /*arg1*/, int /*arg2*/, void* /*common*/) {
  sceKernelExitGame();
  return 0;
}

int callback_thread(SceSize /*args*/, void* /*argp*/) {
  const int cbid =
      sceKernelCreateCallback("Exit Callback", exit_callback, nullptr);
  sceKernelRegisterExitCallback(cbid);
  sceKernelSleepThreadCB();
  return 0;
}

void setup_callbacks(void) {
  const int thid = sceKernelCreateThread("update_thread", callback_thread, 0x11,
                                         0xFA0, 0, nullptr);
  if (thid >= 0)
    sceKernelStartThread(thid, 0, nullptr);
}

void build_ui(void) {
  lv_obj_t* scr = lv_screen_active();
  lv_obj_set_style_bg_color(scr, lv_color_black(), 0);

  lv_obj_t* title = lv_label_create(scr);
  lv_label_set_text(title, "rpg2k on PSP\nHAL bring-up");
  lv_obj_set_style_text_color(title, lv_color_white(), 0);
  lv_obj_align(title, LV_ALIGN_TOP_MID, 0, 10);

  g_status_label = lv_label_create(scr);
  lv_label_set_text(g_status_label, "Keys: (none)");
  lv_obj_set_style_text_color(g_status_label, lv_palette_main(LV_PALETTE_AMBER),
                              0);
  lv_obj_align(g_status_label, LV_ALIGN_CENTER, 0, 20);
}

// Rebuild the "Keys:" line from the current pad bitmask.
void show_keys(uint32_t mask) {
  static uint32_t last = 0xffffffffu;
  if (mask == last)
    return;
  last = mask;

  char buf[64];
  int n = 0;
  n += snprintf(buf + n, sizeof(buf) - n, "Keys:");
  bool any = false;
  for (int k = 0; k < PSP_INPUT_KEY_COUNT && n < static_cast<int>(sizeof(buf));
       ++k) {
    if (mask & (1u << k)) {
      n += snprintf(buf + n, sizeof(buf) - n, " %s", kKeyNames[k]);
      any = true;
    }
  }
  if (!any)
    snprintf(buf + n, sizeof(buf) - n, " (none)");
  lv_label_set_text(g_status_label, buf);
}

}  // namespace

int main(void) {
  // Emitted before any LVGL/display init so the CI smoke test can tell "the
  // EBOOT booted and its stdout is captured" apart from "it crashed during
  // init". A string literal with a compile-time length keeps this marker free
  // of any libc call, so it survives PPSSPP's partial libc HLE.
  static const char kBootMarker[] = "RPG2K_PSP_BOOT\n";
  psp_write(kBootMarker, static_cast<int>(sizeof(kBootMarker) - 1));

  setup_callbacks();

  lv_init();
  psp_display_create(PSP_SCR_WIDTH, PSP_SCR_HEIGHT);
  psp_input_init();
  build_ui();

  // Open the interpreter and report whether it succeeded. `M` is kept alive
  // (never mrb_close()d) for the rest of the process, the same as every other
  // target's entry point -- there is nothing to hand it yet, but the next
  // slice needs it alive for the process's whole lifetime, not just this
  // function.
  mrb_state* const M = mrb_open();
  {
    char buf[48];
    const int n = std::snprintf(buf, sizeof(buf), "RPG2K_PSP_MRUBY_OPEN %s\n",
                                M ? "ok" : "FAILED");
    if (n > 0)
      psp_write(buf, n);
  }

  // The loop runs ~200 iterations/second (5 ms delay); emit a heartbeat line
  // roughly once a second. The CI smoke test asserts this marker appears,
  // proving the EBOOT not only boots but keeps pumping frames (see the
  // psp-smoke job in .github/workflows/build.yml). It also carries real
  // memory numbers -- ADR 0047's P1 -- so the memory-budget estimates there
  // get replaced with device measurements instead of staying host-proxy
  // guesses: sceKernelTotalFreeMemSize/sceKernelMaxFreeMemSize (pspsysmem.h)
  // for the PSP's ~24 MB user partition, and lv_mem_monitor for LVGL's own
  // pool (app/psp/lv_conf.h's 4 MB LV_MEM_SIZE) -- currently used and the
  // max_used high-water mark, which is the number that actually matters for
  // sizing that pool once the interpreter is linked.
  for (uint32_t frame = 0;; ++frame) {
    show_keys(psp_input_scan());
    lv_timer_handler();
    if (frame % 200 == 0) {
      lv_mem_monitor_t mon;
      lv_mem_monitor(&mon);
      char buf[128];
      const int n = std::snprintf(
          buf, sizeof(buf),
          "RPG2K_PSP_BRINGUP frame=%u free=%u maxfree=%u lvgl_used=%u "
          "lvgl_max=%u\n",
          frame, static_cast<unsigned>(sceKernelTotalFreeMemSize()),
          static_cast<unsigned>(sceKernelMaxFreeMemSize()),
          static_cast<unsigned>(mon.total_size - mon.free_size),
          static_cast<unsigned>(mon.max_used));
      if (n > 0)
        psp_write(buf, n);
    }
    sceKernelDelayThread(5000);  // ~5 ms, matching the Wio loop's delay(5)
  }

  sceKernelExitGame();
  return 0;
}
