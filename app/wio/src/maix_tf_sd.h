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
// SCLK/SS to pins 39/36). FPIOA maps FUNC_SPI0_SCLK to one pin at a time, so
// LCD output and SD traffic cannot interleave without re-routing between
// uses. The uploader never inits the LCD, so it is unaffected; the game does
// not mount SD yet (maix_sd_init has no callers) -- whoever wires that up
// must restore the LCD routing around SD use.
#pragma once

#include <SD.h>

#include <SPI.h>

inline SPIClass& maix_tf_spi() {
  static SPIClass spi(SPI0, 11 /*SCLK*/, 6 /*MISO*/, 10 /*MOSI*/, -1);
  return spi;
}

inline SDClass& maix_tf_sd() {
  static SDClass sd(maix_tf_spi());
  return sd;
}
