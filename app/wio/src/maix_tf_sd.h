// TF-slot SD bus for the Maix Amigo. Included by maix_sd_upload_main.cxx and
// maix_sd_syscalls.cxx -- the only two translation units that touch the card.
//
// The TF slot hangs on SPI1 (SCK 11 / MISO 6 / MOSI 10, CS 26), confirmed
// against the official schematic (Maix_Amigo_2960(Schematic).pdf, linked from
// wiki.sipeed.com/soft/maixpy/en/develop_kit_board/maix_amigo.html): every
// one of those four pins carries a net literally named SPI1_SCLK/SPI1_MISO/
// SPI1_MOSI/SPI1_CS_TF on the real PCB. An earlier revision of this file used
// SPI0 instead -- same four pin numbers (the vendored
// sipeed_maix_amigo/pins_arduino.h names them SPI0_MISO/SPI0_MOSI/SPI0_SCLK,
// which is where that came from), but the wrong K210 peripheral. That
// mattered: SPI0 is uniquely an "octal SPI" controller whose 8 data lines are
// pin-shared with the DVP camera interface (sysctl's spi_dvp_data_enable bit
// picks which one drives them), and the LCD (also SPI0, see
// maix_display.cxx) already claims that bit for its own data bus. Landing
// the SD card on SPI0 as well meant fighting the LCD for that one shared
// mux bit -- through manual FPIOA/DVP re-routing between every SD and LCD
// phase -- and a real, reproducible hang partway through the interpreter's
// first data read on real hardware. SPI1 has no such sharing at all: a
// plain, independent SPI controller, so the LCD and the SD card no longer
// have anything to arbitrate.
//
// The SD library's global `SD` object is bound to the default-constructed
// `SPI` (also SPI1, but begin()'s own defaults are 27/26/28 -- the wrong
// pins for the Amigo; the MISO default even collides with the TF
// chip-select), so it can never clock the card: always go through
// maix_tf_sd() instead.
//
// The pins ride in the SPIClass constructor, not in a begin() call:
// Sd2Card::init calls the no-argument spi_.begin(), which would re-route
// FPIOA to begin()'s own defaults; constructor pins are sticky
// (_initPinsInConstruct) and survive that call. CS stays -1 here -- the SD
// library drives pin 26 as GPIO itself. SPIClass::begin()'s own SPI1 branch
// (Maix_SPI.cpp) already routes FUNC_SPI1_SCLK/D0/D1 to these pins with no
// extra help needed -- unlike SPI0, it never touches the DVP mux at all.
#pragma once

#include <SD.h>

#include <SPI.h>

inline SPIClass& maix_tf_spi() {
  static SPIClass spi(SPI1, 11 /*SCLK*/, 6 /*MISO*/, 10 /*MOSI*/, -1);
  return spi;
}

inline SDClass& maix_tf_sd() {
  static SDClass sd(maix_tf_spi());
  return sd;
}
