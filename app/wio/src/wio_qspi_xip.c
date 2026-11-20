// QSPI_XIP: the bc2cpp-compiled gems execute from the external QSPI flash (app/wio/qspi_xip.ld). Their code and
// their static constructors are only reachable once the controller is in memory-read mode, so the window is opened
// from .preinit_array: newlib's __libc_init_array runs it before every .init_array constructor, and the Arduino core
// calls __libc_init_array from main() after SystemInit() set the clocks and before setup(). This file and
// wio_qspi.c are internal-flash code (scripts/wio/qspi_xip_check.rb checks that nothing in the QSPI region is
// reachable from Reset_Handler before this runs).
#include <sam.h>
#include <string.h>

#include "wio_qspi.h"

// The firmware's GNU build-id note (`.note.gnu.build-id`, kept in internal flash by qspi_xip.ld).
extern const uint8_t __wio_build_id_note[];

// No display or serial exists yet, and the constructors that would run next live in the image: blink the user LED
// (PA15) forever instead of running a missing or stale one.
static void halt_blinking(void) {
  PORT->Group[0].DIRSET.reg = 1u << 15;
  for (;;) {
    PORT->Group[0].OUTTGL.reg = 1u << 15;
    for (volatile uint32_t i = 0; i < 6000000u; i++) {
    }
  }
}

static void wio_qspi_xip_preinit(void) {
  wio_qspi_begin();
  wio_qspi_enter_xip();
  wio_cmcc_enable();
  const wio_qspi_header* h = (const wio_qspi_header*)QSPI_AHB;
  // The note's descriptor follows its 12-byte header and the 4-byte "GNU\0" name.
  if (h->magic != WIO_QSPI_MAGIC || memcmp(h->build_id, __wio_build_id_note + 16, WIO_QSPI_BUILD_ID_SIZE) != 0)
    halt_blinking();
}

__attribute__((section(".preinit_array"), used)) static void (*const wio_qspi_xip_preinit_entry)(void) =
    wio_qspi_xip_preinit;
