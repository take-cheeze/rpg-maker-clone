// Maix Amigo firmware entry point -- P0 hello-world + LCD bring-up.
//
// Lives under app/wio/src/ only because platformio.ini sets a single,
// project-wide `src_dir = app/wio/src`: per-env source directories are not a
// thing there, so every environment's files share this directory and select
// via `build_src_filter` (the same reason walk_main.cxx and friends coexist
// here). The port itself is documented in app/maix/README.md.
//
// P0 proves the toolchain produces a binary for the Amigo at all: the K210
// PlatformIO platform (sipeed/platform-kendryte210) ships no Amigo board
// definition, so this environment uses the custom boards/sipeed-maix-amigo.json
// (variant sipeed_maix_amigo from the Maixduino Arduino core). setup() says
// hello over Serial, inits the on-board 320x480 TFT through the Maixduino
// Sipeed_ST7789 driver over SPI0 (the same "MUST be SPI0" shape its own
// basic_display example uses), and loop() blinks the green LED with a Serial
// heartbeat. No LVGL, no mruby, no SD yet -- those are later slices.

#include <Arduino.h>

#include <SPI.h>
#include <Sipeed_ST7789.h>

// lcd_set_direction (the driver's C core, lcd.h, extern "C" itself).
#include <lcd.h>

namespace {

// MUST be SPI0 for the Maix series on-board LCD (per the driver's own
// basic_display example). Amigo LCD pins (CS 36 / RST 37 / DC 38 / WR 39)
// match the driver's defaults, so no pin overrides are needed.
SPIClass g_spi(SPI0);
// 3.5-inch TFT, 320x480. NOTE: early Amigo schematicsrev the panel as TFT
// vs IPS (Maix_Amigo_2960 vs 2970); if this revision's controller answers a
// different init sequence the fill may come out wrong while Serial stays
// correct -- Serial is the proof, the LCD the best effort. See
// app/maix/README.md.
Sipeed_ST7789 g_lcd(320, 480, g_spi);

}  // namespace

void setup(void) {
  Serial.begin(115200);
  Serial.println("maix-amigo hello");

  pinMode(LED_GREEN, OUTPUT);

  g_lcd.begin(15000000, COLOR_BLUE);
  g_lcd.setRotation(0);
  // Un-mirror: the driver installs DIR_YX_RLDU (MADCTL 0xA0), which renders
  // mirrored left-right on this panel (confirmed on hardware). DIR_YX_LRDU
  // (0xE0) keeps MY/MV and flips only the column order bit MX. Must come
  // after setRotation, which re-sends the direction itself.
  lcd_set_direction(DIR_YX_LRDU);
  g_lcd.setTextSize(2);
  g_lcd.setTextColor(COLOR_WHITE);
  g_lcd.setCursor(20, 40);
  g_lcd.println("maix-amigo hello");
  g_lcd.setCursor(20, 80);
  g_lcd.println("320x480 P0");
}

void loop(void) {
  static bool on = false;
  on = !on;
  digitalWrite(LED_GREEN, on ? HIGH : LOW);
  Serial.print("maix-amigo heartbeat: ");
  Serial.println(millis());
  delay(1000);
}
