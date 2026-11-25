// Wio Terminal firmware: writes the external QSPI flash image (a `wio` link's
// firmware_qspi.bin, copied to the microSD card as /qspi.bin) into the board's
// 4 MB QSPI flash, then verifies it through the window the `wio` firmware runs
// it from (app/wio/qspi_xip.ld). Progress and the result go to USB-CDC serial.
// Reflash `wio` afterwards; this loader is not meant to stay flashed.

#include <Arduino.h>
#include <SPI.h>
#include <Seeed_FS.h>

#include "SD/Seeed_SD.h"
#include "wio_qspi.h"

#ifndef SDCARD_SS_PIN
#define SDCARD_SS_PIN 1
#endif
#ifndef SDCARD_SPI
#define SDCARD_SPI SPI
#endif

namespace {

constexpr uint32_t kSector = 4096;
constexpr uint32_t kPage = 256;
constexpr uint32_t kFlashSize = 4u * 1024 * 1024;

uint8_t g_buf[kSector];

bool program(File& f, uint32_t size) {
  for (uint32_t off = 0; off < size; off += kSector) {
    const uint32_t n = min(kSector, size - off);
    if (f.read(g_buf, n) != (int)n) {
      Serial.println("ERR short read from /qspi.bin");
      return false;
    }
    wio_qspi_erase_sector(off);
    for (uint32_t p = 0; p < n; p += kPage)
      wio_qspi_program_page(off + p, g_buf + p, min(kPage, n - p));
    if ((off / kSector) % 64 == 0)
      Serial.print(String("PROGRESS ") + off + "/" + size + "\n");
  }
  return true;
}

bool verify(File& f, uint32_t size) {
  f.seek(0);
  wio_qspi_enter_xip();
  const volatile uint8_t* xip = (const volatile uint8_t*)QSPI_AHB;
  for (uint32_t off = 0; off < size; off += kSector) {
    const uint32_t n = min(kSector, size - off);
    if (f.read(g_buf, n) != (int)n)
      return false;
    for (uint32_t i = 0; i < n; i++) {
      if (xip[off + i] != g_buf[i]) {
        Serial.print(String("ERR verify mismatch at ") + (off + i) + "\n");
        return false;
      }
    }
  }
  return true;
}

}  // namespace

void setup(void) {
  Serial.begin(115200);
  while (!Serial) {
  }
  if (!SD.begin(SDCARD_SS_PIN, SDCARD_SPI)) {
    Serial.println("ERR no SD card");
    return;
  }
  File f = SD.open("/qspi.bin", FILE_READ);
  if (!f) {
    Serial.println("ERR /qspi.bin not found");
    return;
  }
  const uint32_t size = f.size();
  wio_qspi_header h;
  if (size < WIO_QSPI_HEADER_SIZE || size > kFlashSize ||
      f.read(reinterpret_cast<uint8_t*>(&h), sizeof(h)) != sizeof(h) ||
      h.magic != WIO_QSPI_MAGIC || h.length != size - WIO_QSPI_HEADER_SIZE) {
    Serial.print(String("ERR /qspi.bin (") + size +
                 " bytes) is not a firmware_qspi.bin\n");
    return;
  }
  f.seek(0);
  wio_qspi_begin();
  wio_qspi_quad_enable();
  Serial.print(String("PROGRAM ") + size + " bytes\n");
  const bool ok = program(f, size) && verify(f, size);
  f.close();
  Serial.println(ok ? "DONE verified" : "FAILED");
}

void loop(void) {}
