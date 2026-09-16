// TF-slot SD bus for the Maix Amigo. Included by maix_sd_upload_main.cxx and
// maix_sd_syscalls.cxx -- the only two translation units that touch the card.
//
// The TF slot hangs on SPI0 (SCK 11 / MISO 6 / MOSI 10, CS 26 = SPI0_CS0 per
// the sipeed_maix_amigo variant pins). The SD library's global `SD` object is
// bound to the default-constructed `SPI` (SPI1, and begin() defaults
// 27/26/28 -- the wrong bus AND the wrong pins for the Amigo; the MISO
// default even collides with the TF chip-select), so it can never clock the
// card: always go through maix_tf_sd() instead.
//
// The pins ride in the SPIClass constructor, not in a begin() call:
// Sd2Card::init calls the no-argument spi_.begin(), which would re-route
// FPIOA to begin()'s own defaults; constructor pins are sticky
// (_initPinsInConstruct) and survive that call. CS stays -1 here -- the SD
// library drives pin 26 as GPIO itself.
//
// NOTE (game firmware): the LCD also lives on SPI0 (its own driver routes
// SCLK/SS to pins 39/36 and steals the data lines via sysctl DVP mapping).
// FPIOA maps FUNC_SPI0_SCLK to one pin at a time and the sysctl DVP mux
// overrides FPIOA for the data lines, so LCD output and SD traffic cannot
// interleave without re-routing between uses: call maix_spi_take_tf()
// around SD phases and maix_spi_take_lcd() before LCD output resumes. The
// uploader never inits the LCD, so it is unaffected. Title-from-SD uses
// the coarse form (take_tf once at mount, take_lcd latched on the first
// LVGL flush); post-title asset streaming needs full per-op arbitration,
// not yet implemented.
#pragma once

#include <Arduino.h>
#include <SD.h>

#include <SPI.h>
#include <fpioa.h>
#include <sysctl.h>

inline SPIClass& maix_tf_spi() {
  static SPIClass spi(SPI0, 11 /*SCLK*/, 6 /*MISO*/, 10 /*MOSI*/, -1);
  return spi;
}

inline SDClass& maix_tf_sd() {
  static SDClass sd(maix_tf_spi());
  return sd;
}

// Route SPI0 to the TF slot: SCLK/MOSI/MISO to 11/10/6, data lines off the
// DVP mux, LCD deselected (its SS idles high; holding pin 36 high keeps it
// from sampling SD traffic). TF CS (26) stays with the SD library, which
// drives it as GPIO (requires SD.begin to have run at least once).
inline void maix_spi_take_tf() {
  sysctl_set_spi0_dvp_data(0);
  fpioa_set_function(11, FUNC_SPI0_SCLK);
  fpioa_set_function(10, FUNC_SPI0_D0);
  fpioa_set_function(6, FUNC_SPI0_D1);
  pinMode(36, OUTPUT);
  digitalWrite(36, HIGH);
}

// Route SPI0 back to the LCD: SCLK/SS to 39/36 (SS3, matching the Sipeed
// driver's own begin()), data lines back on the DVP mux. Call before any
// LCD output after SD traffic. FPIOA MOSI/MISO entries are left alone;
// the sysctl DVP mux takes precedence over them while enabled.
inline void maix_spi_take_lcd() {
  sysctl_set_spi0_dvp_data(1);
  fpioa_set_function(39, FUNC_SPI0_SCLK);
  fpioa_set_function(36, (fpioa_function_t)(FUNC_SPI0_SS0 + 3));
}
