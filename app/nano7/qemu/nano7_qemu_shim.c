/*
 * nano7_qemu_shim -- the bare-metal-under-QEMU platform half of a
 * hb_raw_surface/hb_sdk implementation for app/nano7/rpg2k_walk/rpg2k_walk.c.
 *
 * Unlike app/nano7/host (docs/adr/0102), which runs the app natively on the
 * build host with zero relation to real device timing, this target links
 * the app against the REAL arm-none-eabi-gcc -mcpu=cortex-a8 build (the
 * same compiler invocation NanoApps' own sdk/hb_app.mk uses) and boots it
 * under QEMU's `cortex-a8` CPU model on the `realview-pb-a8` machine -- a
 * real ARM Cortex-A8 instruction stream, not native host execution, giving
 * a genuine (if approximate -- see docs/adr/0103) CPU cost signal the host
 * build cannot give at all. Framebuffer pixels land in real, guest-visible
 * RAM that a real PL110 CLCD controller model scans out, verified pixel-
 * correct against QEMU's own `screendump` (see scripts/nano7_qemu_run.bash).
 *
 * hb_raw_fb(), the hb_raw_ pixel primitives and hb_draw_str are
 * app/nano7/shim_common/hb_fb_ops.c, shared with app/nano7/host. This file
 * supplies everything platform-specific instead: hb_fs_read (over two
 * linked-in binary blobs -- no filesystem, no SD card, deliberately out of
 * scope, see the ADR), hb_time_uptime_ms (a harness-advanced counter, same
 * convention as the host build's headless mode -- there is no real-time
 * clock peripheral wired up here either, on purpose), the PL011 UART used
 * only for this file's own progress/cycle-count log (never by the app,
 * which never calls anything UART-shaped), the PL110 CLCD setup, the
 * Cortex-A8 PMU cycle counter, and main().
 *
 * This file, like app/nano7/host/nano7_host_shim.c, links
 * app/nano7/rpg2k_walk/rpg2k_walk.c and
 * app/shared/rpg2k_walk/rpg2k_walk_core.c completely unmodified.
 */
#include <stdint.h>

#include "hb_raw_surface.h"
#include "hb_sdk.h"

extern uint32_t *hb_raw_fb(void);

/* ---- PL011 UART0 (this file's own debug/log output only) ----
 *
 * Base address and register offsets read from QEMU's own `info mtree`
 * (pl011 @ 0x10009000) and verified by booting a UART-only test image
 * against it before this file existed -- not assumed from a datasheet. */
#define UART0_BASE 0x10009000u
#define UART_DR (*(volatile uint32_t *)(UART0_BASE + 0x00))
#define UART_FR (*(volatile uint32_t *)(UART0_BASE + 0x18))
#define UART_CR (*(volatile uint32_t *)(UART0_BASE + 0x30))
#define UART_FR_TXFF (1u << 5)

static void uart_putc(char c) {
  while (UART_FR & UART_FR_TXFF) {}
  UART_DR = (uint32_t)(uint8_t)c;
}
static void uart_puts(const char *s) {
  for (; *s; s++) uart_putc(*s);
}
static void uart_puthex(uint32_t v) {
  uart_puts("0x");
  for (int i = 28; i >= 0; i -= 4) {
    uint32_t nib = (v >> i) & 0xfu;
    uart_putc(nib < 10 ? (char)('0' + nib) : (char)('a' + nib - 10));
  }
}
static void uart_putdec(uint32_t v) {
  char buf[11];
  int i = 10;
  buf[i] = '\0';
  do {
    buf[--i] = (char)('0' + (v % 10u));
    v /= 10u;
  } while (v);
  uart_puts(&buf[i]);
}

/* ---- PL110 CLCD (the real display peripheral) ----
 *
 * Base address 0x10020000 and the CNTL/IENB register swap on realview
 * boards: both from QEMU's own `info mtree` plus upstream Linux's
 * include/linux/amba/clcd.h (the realview #ifdef branch), read directly
 * rather than assumed. TIM0/TIM1's PPL/LPP field formulas are that same
 * driver's clcdfb_decode(). The CNTL_BGR bit and the LCDBPP24 encoding
 * (24bpp packed into a 32-bit word, matching HB_RGB's own 0x00RRGGBB
 * layout with zero per-pixel conversion) were verified pixel-correct via
 * QEMU `screendump` against a hand-drawn red/blue test pattern before this
 * file existed -- see docs/adr/0103. */
#define CLCD_BASE 0x10020000u
#define CLCD_TIM0 (*(volatile uint32_t *)(CLCD_BASE + 0x00))
#define CLCD_TIM1 (*(volatile uint32_t *)(CLCD_BASE + 0x04))
#define CLCD_TIM2 (*(volatile uint32_t *)(CLCD_BASE + 0x08))
#define CLCD_TIM3 (*(volatile uint32_t *)(CLCD_BASE + 0x0C))
#define CLCD_UBAS (*(volatile uint32_t *)(CLCD_BASE + 0x10))
#define CLCD_CNTL (*(volatile uint32_t *)(CLCD_BASE + 0x18)) /* swapped w/ IENB on realview */

#define CNTL_LCDEN (1u << 0)
#define CNTL_LCDBPP24 (5u << 1)
#define CNTL_LCDTFT (1u << 5)
#define CNTL_BGR (1u << 8)
#define CNTL_LCDPWR (1u << 11)

static void clcd_init(void) {
  uint32_t fb_addr = (uint32_t)(uintptr_t)hb_raw_fb();
  CLCD_TIM0 = ((HB_SCREEN_W / 16) - 1) << 2;
  CLCD_TIM1 = (HB_SCREEN_H - 1);
  CLCD_TIM2 = 0;
  CLCD_TIM3 = 0;
  CLCD_UBAS = fb_addr;
  /* Per the real PL110 TRM's enable sequence: everything but LCDPWR first,
   * LCDPWR set afterwards. QEMU's model does not appear to require the
   * delay a real panel's power rail would, but the two-step order is kept
   * for fidelity to the real sequence rather than relying on that. */
  CLCD_CNTL = CNTL_LCDEN | CNTL_LCDBPP24 | CNTL_LCDTFT | CNTL_BGR;
  CLCD_CNTL |= CNTL_LCDPWR;
}

/* ---- Cortex-A8 PMU cycle counter (CP15 c9) ----
 *
 * Standard ARMv7-A performance-monitor registers, not chip-specific.
 * Verified against QEMU's cortex-a8 model directly before this file
 * existed: a busy-loop of N iterations gives a CCNT delta that scales
 * with N (roughly 10x for a 10x longer loop), so this is a real, working
 * counter under QEMU's TCG, not a stub that reads back zero. See
 * docs/adr/0103 for exactly what this number does and does not mean --
 * in short, a repeatable, comparable-across-builds proxy for CPU work,
 * the same relative-signal role Renode's `machine EnableProfiler` plays
 * for the Wio Terminal (docs/adr/0094), not literal hardware nanoseconds. */
static inline void pmu_enable(void) {
  uint32_t ctrl;
  __asm__ volatile("mrc p15, 0, %0, c9, c12, 0" : "=r"(ctrl));
  ctrl |= (1u << 0) | (1u << 2); /* E: enable | C: reset cycle counter */
  __asm__ volatile("mcr p15, 0, %0, c9, c12, 0" ::"r"(ctrl));
  uint32_t ccnt_en = (1u << 31); /* PMCNTENSET: enable the cycle counter */
  __asm__ volatile("mcr p15, 0, %0, c9, c12, 1" ::"r"(ccnt_en));
}
static inline uint32_t pmu_ccnt(void) {
  uint32_t v;
  __asm__ volatile("mrc p15, 0, %0, c9, c13, 0" : "=r"(v));
  return v;
}

/* ---- hb_sdk.h's platform-specific half ---- */

/* rpg2k_walk.c only ever reads two fixed paths (MAP_DATA_DIR "/map.bin" and
 * ".../tiles.bin"); this target has no filesystem at all, so hb_fs_read
 * just matches the path suffix and copies from one of two blobs linked
 * into the image (scripts/nano7_qemu_build.bash's objcopy step). */
extern const uint8_t _binary_map_bin_start[];
extern const uint8_t _binary_map_bin_end[];
extern const uint8_t _binary_tiles_bin_start[];
extern const uint8_t _binary_tiles_bin_end[];

static int ends_with(const char *s, const char *suffix) {
  int ls = 0, lf = 0;
  while (s[ls]) ls++;
  while (suffix[lf]) lf++;
  if (lf > ls) return 0;
  for (int i = 0; i < lf; i++)
    if (s[ls - lf + i] != suffix[i]) return 0;
  return 1;
}

uint32_t hb_fs_read(const char *path, void *buf, uint32_t max_size) {
  const uint8_t *start, *end;
  if (ends_with(path, "map.bin")) {
    start = _binary_map_bin_start;
    end = _binary_map_bin_end;
  } else if (ends_with(path, "tiles.bin")) {
    start = _binary_tiles_bin_start;
    end = _binary_tiles_bin_end;
  } else {
    return 0;
  }
  uint32_t len = (uint32_t)(end - start);
  if (len > max_size) len = max_size;
  uint8_t *dst = (uint8_t *)buf;
  for (uint32_t i = 0; i < len; i++) dst[i] = start[i];
  return len;
}

/* No RTC/timer peripheral wired up (deliberately -- see the file header):
 * a harness-advanced counter, exactly like app/nano7/host's headless mode,
 * so rpg2k_walk.c's STEP_INTERVAL_MS-gated movement fires on an exact,
 * reproducible schedule. */
static uint32_t s_sim_ms;
uint32_t hb_time_uptime_ms(void) { return s_sim_ms; }

/* ---- the harness ---- */

#define RUN_FRAMES 60

void main(void) {
  UART_CR = (1u << 0) | (1u << 8); /* UARTEN | TXE */
  uart_puts("NANO7-QEMU boot\n");

  clcd_init();
  pmu_enable();

  uint32_t c0 = pmu_ccnt();
  hb_raw_init(HB_SCREEN_W, HB_SCREEN_H);
  uint32_t c1 = pmu_ccnt();
  uart_puts("NANO7-QEMU init cycles=");
  uart_puthex(c1 - c0);
  uart_putc('\n');

  s_sim_ms = 0;
  hb_spoint_t touch = {0, 0, 0};
  for (int i = 0; i < RUN_FRAMES; i++) {
    if (i >= 3) {
      touch.down = 1;
      touch.x = HB_SCREEN_W / 2;
      touch.y = (int16_t)(HB_SCREEN_H / 2 + 80);
    }
    uint32_t f0 = pmu_ccnt();
    hb_raw_frame(&touch);
    uint32_t f1 = pmu_ccnt();
    s_sim_ms += 20;

    uart_puts("NANO7-QEMU frame=");
    uart_putdec((uint32_t)i);
    uart_puts(" cycles=");
    uart_puthex(f1 - f0);
    uart_putc('\n');
  }

  uart_puts("NANO7-QEMU done\n");
  for (;;) {}
}
