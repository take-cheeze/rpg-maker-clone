// QSPI_XIP: opens the external flash window the cold code runs from
// (app/wio/qspi_xip.ld) and checks the image there belongs to this firmware.
// It runs from .preinit_array: newlib's __libc_init_array calls it before any
// static constructor, after the Arduino core's init() set the clocks. Nothing
// it reaches is in QSPI (scripts/wio/qspi_xip_check.rb), and no constructor
// reaches QSPI either, so a bad image is reported from setup() instead of
// crashing on the first jump into it.
#include "wio_qspi_xip.h"

#if WIO_QSPI_XIP

#include <Arduino.h>
#include <TFT_eSPI.h>
#include <sam.h>
#include <string.h>

#include <cstdio>

#include "wio_qspi.h"

extern "C" const uint8_t __wio_build_id_note[];
extern "C" const uint8_t __qspi_image_start[];
extern "C" const uint8_t __qspi_image_end[];

namespace {

int g_status = WIO_QSPI_XIP_UNCHECKED;

int check_image() {
  const wio_qspi_header* h =
      reinterpret_cast<const wio_qspi_header*>(__qspi_image_start);
  if (h->magic != WIO_QSPI_MAGIC)
    return WIO_QSPI_XIP_NO_IMAGE;
  // The note's descriptor follows its 12-byte header and the 4-byte "GNU\0".
  if (memcmp(h->build_id, __wio_build_id_note + 16, WIO_QSPI_BUILD_ID_SIZE) !=
          0 ||
      h->length != static_cast<uint32_t>(__qspi_image_end - __qspi_image_start -
                                         WIO_QSPI_HEADER_SIZE))
    return WIO_QSPI_XIP_STALE;
  const volatile uint8_t* payload = __qspi_image_start + WIO_QSPI_HEADER_SIZE;
  const uint32_t blocks = (h->length + WIO_QSPI_BLOCK - 1) / WIO_QSPI_BLOCK;
  uint32_t crc = 0;
  for (uint32_t i = 0; i < blocks; i++) {
    // stride < blocks, and a 4 MB image has at most 16384 blocks: no overflow.
    const uint32_t b = i * h->stride % blocks;
    const uint32_t off = b * WIO_QSPI_BLOCK;
    const uint32_t n =
        h->length - off < WIO_QSPI_BLOCK ? h->length - off : WIO_QSPI_BLOCK;
    crc = wio_crc32(crc, payload + off, n);
  }
  return crc == h->crc32 ? WIO_QSPI_XIP_OK : WIO_QSPI_XIP_CORRUPT;
}

void preinit() {
  wio_qspi_begin();
  wio_qspi_enter_xip();
  wio_cmcc_enable();
  g_status = check_image();
}

__attribute__((section(".preinit_array"),
               used)) void (*const kPreinit)() = preinit;

}  // namespace

extern "C" int wio_qspi_xip_status(void) {
  return g_status;
}

extern "C" const char* wio_qspi_xip_status_text(void) {
  switch (g_status) {
    case WIO_QSPI_XIP_OK:
      return "QSPI image OK";
    case WIO_QSPI_XIP_NO_IMAGE:
      return "No QSPI image: program firmware_qspi.bin (wio_qspi_flash)";
    case WIO_QSPI_XIP_STALE:
      return "QSPI image is from another build: program its firmware_qspi.bin";
    case WIO_QSPI_XIP_CORRUPT:
      return "QSPI image does not read back (CRC mismatch)";
    default:
      return "QSPI window never opened";
  }
}

extern "C" void wio_qspi_xip_require(void) {
  if (g_status == WIO_QSPI_XIP_OK)
    return;
  const char* text = wio_qspi_xip_status_text();
  std::fprintf(stderr, "[QSPI] %s\n", text);
  // Static: TFT_eSPI's constructor leaves some fields (the font) to the
  // zero-initialisation a global or static gets.
  static TFT_eSPI tft;
  tft.begin();
  tft.setRotation(3);
  tft.fillScreen(TFT_RED);
  tft.setTextColor(TFT_WHITE, TFT_RED);
  tft.setTextSize(2);
  tft.setCursor(0, 8);
  tft.println("Cannot start:");
  tft.println(text);
  Serial.begin(115200);
  pinMode(LED_BUILTIN, OUTPUT);
  for (bool on = false;; on = !on) {
    Serial.print("[QSPI] ");
    Serial.println(text);
    digitalWrite(LED_BUILTIN, on ? HIGH : LOW);
    delay(500);
  }
}

#endif  // WIO_QSPI_XIP
