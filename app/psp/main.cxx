// PlayStation Portable EBOOT entry point -- hardware bring-up.
//
// This first slice proves the HAL compiles and runs on the PSP without the
// mruby interpreter: it stands up the LVGL display (psp_display_create), scans
// the pad (psp_input_scan), and draws a small status screen that echoes the
// pressed keys. main() owns the loop and pumps LVGL once per iteration -- the
// same "host owns the loop" shape the Emscripten and Wio builds use.
//
// The mruby interpreter, the real RPG2k scene tree and Memory-Stick asset
// loading are wired in the following slices (see app/psp/README.md and
// docs/adr/0010-psp-port.md); this build intentionally links neither libmruby
// nor the mruby input bridge.

#include <cstdio>
#include <cstring>

#include <lvgl.h>
#include <pspiofilemgr.h>
#include <pspkernel.h>

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

// Write a NUL-terminated string to the PSP stdout (fd 1) and stderr (fd 2).
// Under an emulator the host captures these; on real hardware they go nowhere.
// Plain printf is an unimplemented HLE import under PPSSPP (a silent no-op), so
// the raw sceIoWrite is used for the CI markers; both fds are written so
// whichever one PPSSPP surfaces to its log is captured.
void psp_write(const char* s) {
  const int len = static_cast<int>(std::strlen(s));
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
  // init".
  psp_write("RPG2K_PSP_BOOT\n");

  setup_callbacks();

  lv_init();
  psp_display_create(PSP_SCR_WIDTH, PSP_SCR_HEIGHT);
  psp_input_init();
  build_ui();

  // The loop runs ~200 iterations/second (5 ms delay); emit a heartbeat line
  // roughly once a second. The CI smoke test asserts this marker appears,
  // proving the EBOOT not only boots but keeps pumping frames (see the
  // psp-smoke job in .github/workflows/build.yml).
  for (uint32_t frame = 0;; ++frame) {
    show_keys(psp_input_scan());
    lv_timer_handler();
    if (frame % 200 == 0) {
      char buf[48];
      std::snprintf(buf, sizeof(buf), "RPG2K_PSP_BRINGUP frame=%u\n", frame);
      psp_write(buf);
    }
    sceKernelDelayThread(5000);  // ~5 ms, matching the Wio loop's delay(5)
  }

  sceKernelExitGame();
  return 0;
}
