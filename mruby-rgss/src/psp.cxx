// PlayStation Portable (Allegrex / pspsdk) LVGL display + input HAL. See
// include/psp.hxx for the contract and why this file is a no-op unless
// PSP_BUILD is defined.

#ifdef PSP_BUILD

#include "psp.hxx"

#include <cstring>

#include <pspctrl.h>
#include <pspdisplay.h>
#include <pspge.h>
#include <pspkernel.h>

namespace {

// The VRAM framebuffer the display controller scans out. Filled in by
// psp_display_create() from the edram base; addressed through the uncached
// mirror (| 0x40000000) so writes are visible to the display without a manual
// cache writeback.
uint16_t* g_fb = nullptr;

// Physical-pixel offset of the logical canvas's (0, 0) origin, set once by
// psp_display_create() from the requested hor_res/ver_res. RPG2k's native
// 320x240 is smaller than the 480x272 panel in both dimensions, so it is
// centered with a positive offset (black bars, no scaling). RPG XP's 640x480
// and RPG VX/VX Ace's 544x416 are each larger than the panel in *both*
// dimensions (they were designed for a desktop window, not a handheld LCD) --
// there is no offset that fits them, so they get a negative offset instead,
// centering a same-scale *window* onto the middle of the game's own canvas:
// content runs at its correct native resolution and everything RGSS-side
// (Graphics.width/height, mouse-free coordinate math) is unaffected, but
// anything drawn near an edge of a XP/VX screen -- a window docked in a
// corner, say -- falls outside the visible 480x272 and is simply never
// flushed. flush_cb clips every row to the panel's bounds either way, so
// this is a real, known limitation (not full-canvas scaling, which would
// need per-pixel resampling this bring-up doesn't attempt) but not a
// correctness or memory-safety one.
int32_t g_offset_x = 0;
int32_t g_offset_y = 0;

// LVGL partial-render draw buffers, in main RAM. Quarter-screen each
// (480 * 68 * 2 = ~64 KB); two buffers let LVGL render one while the other is
// being copied out. The PSP has ~24 MB of user RAM, so unlike the Wio backend
// these are comfortable -- kept partial only to bound peak working set.
constexpr int32_t kBufRows = PSP_SCR_HEIGHT / 4;
uint8_t g_buf1[PSP_SCR_WIDTH * kBufRows * 2];
uint8_t g_buf2[PSP_SCR_WIDTH * kBufRows * 2];

// LVGL needs a millisecond tick and a delay without SDL. The pspsdk system
// timer is microseconds; wrap it so the function-pointer types match exactly
// (sceKernelGetSystemTimeLow returns u32 microseconds).
uint32_t tick_cb(void) {
  return sceKernelGetSystemTimeLow() / 1000u;
}

void delay_cb(uint32_t ms) {
  sceKernelDelayThread(ms * 1000u);
}

// Copy one rendered rectangle into the VRAM framebuffer. LVGL hands RGB565
// pixels packed at the rectangle's own width, in the *logical* canvas's
// coordinate space; g_offset_x/g_offset_y translate that into panel-relative
// coordinates (see the comment above them), and every row is clipped to the
// panel's actual 480x272 bounds before it is copied -- required whenever the
// logical canvas is larger than the panel (RPG XP/VX/VX Ace), since an
// unclipped row or column would land outside g_fb's PSP_BUF_WIDTH * 272
// allocation. The framebuffer's fixed 512-pixel line stride is accounted for
// in the destination row stride either way.
//
// NOTE: the PSP's 565 display format is BGR-ordered (red in the low 5 bits)
// while LVGL's RGB565 puts red high, so the red/blue channels are swapped on
// screen. Harmless for this bring-up (it still proves display + input); when
// the real scene tree lands this is the one knob to fix -- either a per-pixel
// swap here or an LVGL BGR color format -- verified against PPSSPP.
void flush_cb(lv_display_t* disp, const lv_area_t* area, uint8_t* px_map) {
  const int32_t w = lv_area_get_width(area);
  const int32_t h = lv_area_get_height(area);
  const uint16_t* src = reinterpret_cast<const uint16_t*>(px_map);

  for (int32_t row = 0; row < h; ++row) {
    const int32_t dst_y = area->y1 + row + g_offset_y;
    const uint16_t* row_src = src;
    src += w;
    if (dst_y < 0 || dst_y >= PSP_SCR_HEIGHT)
      continue;

    int32_t dst_x = area->x1 + g_offset_x;
    int32_t copy_w = w;
    if (dst_x < 0) {
      // The row's first -dst_x source pixels land left of the panel.
      row_src -= dst_x;
      copy_w += dst_x;
      dst_x = 0;
    }
    if (dst_x + copy_w > PSP_SCR_WIDTH)
      copy_w = PSP_SCR_WIDTH - dst_x;
    if (copy_w <= 0)
      continue;

    uint16_t* dst = g_fb + dst_y * PSP_BUF_WIDTH + dst_x;
    std::memcpy(dst, row_src, static_cast<size_t>(copy_w) * 2);
  }

  lv_display_flush_ready(disp);
}

}  // namespace

lv_display_t* psp_display_create(int32_t hor_res, int32_t ver_res) {
  // Point the display controller at the start of VRAM (uncached mirror) with a
  // 512-pixel stride in RGB565.
  g_fb = reinterpret_cast<uint16_t*>(
      reinterpret_cast<uintptr_t>(sceGeEdramGetAddr()) | 0x40000000u);
  std::memset(g_fb, 0, static_cast<size_t>(PSP_BUF_WIDTH) * PSP_SCR_HEIGHT * 2);

  sceDisplaySetMode(0, PSP_SCR_WIDTH, PSP_SCR_HEIGHT);
  sceDisplaySetFrameBuf(g_fb, PSP_BUF_WIDTH, PSP_DISPLAY_PIXEL_FORMAT_565,
                        PSP_DISPLAY_SETBUF_NEXTFRAME);

  lv_tick_set_cb(tick_cb);
  lv_delay_set_cb(delay_cb);

  // Center the logical canvas on the panel (see the g_offset_x/y comment
  // above): positive when it is smaller than the panel (RPG2k's 320x240),
  // negative when larger (RPG XP/VX/VX Ace), either way computed once here
  // rather than per flush.
  g_offset_x = (PSP_SCR_WIDTH - hor_res) / 2;
  g_offset_y = (PSP_SCR_HEIGHT - ver_res) / 2;

  lv_display_t* disp = lv_display_create(hor_res, ver_res);
  if (!disp)
    return nullptr;

  lv_display_set_color_format(disp, LV_COLOR_FORMAT_RGB565);
  lv_display_set_buffers(disp, g_buf1, g_buf2, sizeof(g_buf1),
                         LV_DISPLAY_RENDER_MODE_PARTIAL);
  lv_display_set_flush_cb(disp, flush_cb);
  return disp;
}

void psp_input_init(void) {
  sceCtrlSetSamplingCycle(0);
  sceCtrlSetSamplingMode(PSP_CTRL_MODE_ANALOG);
}

uint32_t psp_input_scan(void) {
  SceCtrlData pad;
  if (sceCtrlReadBufferPositive(&pad, 1) < 0)
    return 0;

  uint32_t mask = 0;
  const uint32_t b = pad.Buttons;

  if (b & PSP_CTRL_UP)
    mask |= (1u << PSP_INPUT_UP);
  if (b & PSP_CTRL_DOWN)
    mask |= (1u << PSP_INPUT_DOWN);
  if (b & PSP_CTRL_LEFT)
    mask |= (1u << PSP_INPUT_LEFT);
  if (b & PSP_CTRL_RIGHT)
    mask |= (1u << PSP_INPUT_RIGHT);

  // Analog stick as a coarse D-pad. 0..255, centre 128; a generous deadzone
  // keeps a resting stick from registering.
  if (pad.Ly < 64)
    mask |= (1u << PSP_INPUT_UP);
  else if (pad.Ly > 192)
    mask |= (1u << PSP_INPUT_DOWN);
  if (pad.Lx < 64)
    mask |= (1u << PSP_INPUT_LEFT);
  else if (pad.Lx > 192)
    mask |= (1u << PSP_INPUT_RIGHT);

  // Cross = confirm (C), Circle = cancel (B), Triangle = A, matching the
  // desktop Z/X/C convention so the same games play the same way.
  if (b & PSP_CTRL_CROSS)
    mask |= (1u << PSP_INPUT_C);
  if (b & PSP_CTRL_CIRCLE)
    mask |= (1u << PSP_INPUT_B);
  if (b & PSP_CTRL_TRIANGLE)
    mask |= (1u << PSP_INPUT_A);

  return mask;
}

#endif  // PSP_BUILD
