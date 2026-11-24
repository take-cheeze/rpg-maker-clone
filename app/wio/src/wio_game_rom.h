// The game image the wio_renode_game firmware reads its files from, and the
// diagnostic text window it writes its log to. Both live outside the board's
// 192 KB of SRAM, so the heap it measures is the firmware's own.
//
// Image layout (scripts/wio/game_rom.rb writes it), all little-endian u32:
//   "WIOGROM1" magic, entry count, config offset, config length,
//   then per entry: path offset, data offset, data length.
// Paths are NUL-terminated and absolute ("/rom/RPG_RT.ldb"); the config is
// "key=value" lines (see wio_renode_game_main.cxx).
#pragma once

#include <cstddef>
#include <cstdint>

// The Wio's QSPI flash XIP window; app/wio/renode/game_rom.repl maps the image
// there. 16 MB, the window's size, not the real chip's 4 MB.
constexpr uintptr_t kGameRomBase = 0x04000000;
constexpr size_t kGameRomSize = 0x01000000;
// No memory on the real board: game_rom.repl maps it for the log only.
constexpr uintptr_t kDiagBase = 0x06000000;
constexpr size_t kDiagSize = 0x10000;

// The config value for +key+ (NUL-terminated copy into buf), or nullptr.
const char* wio_game_rom_config(const char* key, char* buf, size_t cap);
// Appends to the diagnostic log (stdout/stderr land here too).
void wio_diag_write(const char* text, size_t len);
void wio_diag_printf(const char* fmt, ...)
    __attribute__((format(printf, 1, 2)));
// Bytes of the log written so far (the end marker the Renode script reads).
size_t wio_diag_length();
