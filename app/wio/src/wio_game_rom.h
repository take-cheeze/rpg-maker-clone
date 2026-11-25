// The game image in the QSPI flash the firmware reads its files from
// (wio_game_rom.cxx, which also serves them from the microSD card), and the
// wio_renode_game firmware's diagnostic text window (wio_renode_diag.cxx).
// Both live outside the board's 192 KB of SRAM, so the heap it measures is
// the firmware's own.
//
// Image layout (scripts/wio/game_rom.rb writes it), all little-endian u32:
//   "WIOGROM1" magic, entry count, config offset, config length,
//   then per entry: path offset, data offset, data length.
// Paths are NUL-terminated and absolute ("/rom/RPG_RT.ldb"); the config is
// "key=value" lines (see wio_renode_game_main.cxx).
#pragma once

#include <cstddef>
#include <cstdint>

// GAME_DIR: a path under it comes from the card's game folder when the card
// has one (wio_sd.h), else from the image.
#define WIO_GAME_ROOT "/rom"

// Where the image starts in the Wio's QSPI flash window (app/wio/renode/
// game_rom.repl maps 16 MB there, the window's size, not the real chip's 4 MB):
// after the code image when app/wio/qspi_xip.ld places one at the window's
// start, else at the start.
extern "C" const uint8_t __wio_game_rom_base[] __attribute__((weak));
inline uintptr_t game_rom_base() {
  return __wio_game_rom_base ? reinterpret_cast<uintptr_t>(__wio_game_rom_base)
                             : 0x04000000;
}
// No memory on the real board: game_rom.repl maps it for the log only.
constexpr uintptr_t kDiagBase = 0x06000000;
constexpr size_t kDiagSize = 0x10000;

// Whether the image's header is there.
bool wio_game_rom_present();
// Mounts the card (wio_sd_begin) and picks where the game's files come from:
// a one-line summary for the screen, also logged with a [Wio] tag.
const char* wio_game_files_begin();
// The config value for +key+ (NUL-terminated copy into buf), or nullptr.
const char* wio_game_rom_config(const char* key, char* buf, size_t cap);
// The bytes of the image's file at +path+, in place, or nullptr (never the
// card's).
const void* wio_game_rom_file(const char* path, size_t* len);
// Appends to the diagnostic log (stdout/stderr land here too).
void wio_diag_write(const char* text, size_t len);
void wio_diag_printf(const char* fmt, ...)
    __attribute__((format(printf, 1, 2)));
// Bytes of the log written so far (the end marker the Renode script reads).
size_t wio_diag_length();
