// The Wio Terminal's external 4 MB QSPI flash (PA08-PA11 data, PB10 SCK, PB11
// CS). The `wio` firmware executes code from it in place (app/wio/qspi_xip.ld);
// the wio_qspi_flash loader programs it. Register-level only, and kept in
// internal flash: it runs before the window can be read.
#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// QSPI_IMAGE_HEADER: the first 32 bytes of the image at 0x04000000, written by
// app/wio/qspi_xip.py. `crc32` (zlib's) covers the `length` bytes after the
// header, read in 256-byte blocks in the order block (i * stride) % blocks, so
// that checking it also exercises reads at non-sequential addresses.
#define WIO_QSPI_MAGIC 0x50495857u /* "WXIP" */
#define WIO_QSPI_HEADER_SIZE 32u
#define WIO_QSPI_BLOCK 256u
// The first 16 bytes of the GNU build-id.
#define WIO_QSPI_BUILD_ID_SIZE 16u

typedef struct {
  uint32_t magic;
  uint32_t length;
  uint32_t crc32;
  uint32_t stride;
  uint8_t build_id[WIO_QSPI_BUILD_ID_SIZE];
} wio_qspi_header;

// Clocks, pins and the controller in serial-memory mode at the variant's QSPI
// clock (at most VARIANT_QSPI_BAUD_DEFAULT).
void wio_qspi_begin(void);
// One flash command in instruction mode. `addr` < 0 sends none; `buf`/`len` are
// the data phase (`write`: to flash).
void wio_qspi_command(uint8_t cmd,
                      int32_t addr,
                      uint8_t* buf,
                      uint32_t len,
                      int write);
// Sets the flash's (non-volatile) Quad Enable bit when it is clear: Quad Output
// Fast Read needs it.
void wio_qspi_quad_enable(void);
void wio_qspi_erase_sector(uint32_t addr);  // 4 KB, 0x20
// At most 256 bytes within one page, 0x02.
void wio_qspi_program_page(uint32_t addr, const uint8_t* data, uint32_t len);
// Quad Output Fast Read (0x6B) as the memory-read instruction: from here on a
// CPU read of 0x04000000 + n reads flash offset n. No other command may be
// issued afterwards.
void wio_qspi_enter_xip(void);
// The CMCC: the 4 KB cache on the code bus, in front of both the internal
// flash and the QSPI window.
void wio_cmcc_enable(void);
// zlib's CRC-32 of `len` bytes, continuing from `crc` (0 to start).
uint32_t wio_crc32(uint32_t crc, const volatile uint8_t* p, uint32_t len);

#ifdef __cplusplus
}
#endif
