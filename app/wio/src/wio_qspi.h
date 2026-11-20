// Wio Terminal external QSPI flash (4 MB on PA08-PA11 / PB10 SCK / PB11 CS,
// variant.cpp pins 55..60). The firmware executes the bc2cpp-compiled gems from
// it in place (app/wio/qspi_xip.ld); the wio_qspi_flash loader programs it.
// Everything here is register-level and lives in internal flash: it runs before
// the XIP window exists.
#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// QSPI_IMAGE_HEADER: the first 32 bytes of the image at 0x04000000
// (`.qspi_header`, qspi_xip.ld): a magic word, the image length, then the
// firmware's GNU build-id, written there by app/wio/qspi_image.py. The firmware
// runs the image only when the header's build-id is its own.
#define WIO_QSPI_MAGIC 0x49505351u /* "QSPI" */
#define WIO_QSPI_HEADER_SIZE 32u
#define WIO_QSPI_BUILD_ID_SIZE 20u

typedef struct {
  uint32_t magic;
  uint32_t length; /* bytes after the header */
  uint8_t build_id[WIO_QSPI_BUILD_ID_SIZE];
  uint32_t reserved;
} wio_qspi_header;

// Clocks, pins and the controller in SPI-memory mode at the variant's QSPI
// clock, with the flash's Quad Enable bit set (non-volatile; written only when
// clear).
void wio_qspi_begin(void);
// One flash command in instruction mode. `addr` < 0 sends none; `buf`/`len` are
// the data phase (`write`: to flash).
void wio_qspi_command(uint8_t cmd,
                      int32_t addr,
                      uint8_t* buf,
                      uint32_t len,
                      int write);
void wio_qspi_wait_ready(void);
void wio_qspi_erase_sector(uint32_t addr);  // 4 KB, 0x20
void wio_qspi_program_page(uint32_t addr,
                           const uint8_t* data,
                           uint32_t len);  // <= 256 B within one page, 0x02
// Quad Output Fast Read (0x6B) as the controller's memory-read instruction:
// from here on a CPU read of 0x04000000 + n reads flash offset n, cached by
// CMCC. No other command may be issued afterwards.
void wio_qspi_enter_xip(void);
// The CMCC (4 KB cache in front of the code bus, which the internal flash and
// the QSPI window share).
void wio_cmcc_enable(void);

#ifdef __cplusplus
}
#endif
