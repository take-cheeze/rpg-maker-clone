// The microSD ("TF") card as the source of the game's files (wio_sd.cxx).
// WIO_SD is 1 when app/wio/wio_sd.py builds the card driver in; WIO_SD=0 at
// build time leaves it out, and every game file comes from the QSPI image.
#pragma once

#include <cstddef>
#include <cstdint>

#ifndef WIO_SD
#define WIO_SD 0
#endif

// The card's game folder: the game's own folder contents (RPG_RT.ldb, ...).
#define WIO_SD_GAME_DIR "/rpg2k"

enum WioSdState {
  WIO_SD_OFF,            // built with WIO_SD=0
  WIO_SD_NO_CARD,        // no card answered, or the driver failed
  WIO_SD_NO_FILESYSTEM,  // a card, but no FAT12/16/32 volume on it
  WIO_SD_NO_GAME,        // no WIO_SD_GAME_DIR/RPG_RT.ldb on the card
  WIO_SD_GAME,           // game files come from the card
};

// Mounts the card and looks for the game folder, logging the outcome with a
// [Wio] tag. Call once, at boot; later calls return the first outcome.
WioSdState wio_sd_begin();
WioSdState wio_sd_state();
const char* wio_sd_state_text(WioSdState state);

#if WIO_SD
// +rel+ is a UTF-8 path below the game folder ("Title/x.png"). A handle, or
// -errno (ENOENT for a file that is not there, EIO for a card error).
int wio_sd_open(const char* rel);
void wio_sd_close(int h);
// Bytes read (0 at the end), or -EIO.
int wio_sd_read(int h, void* buf, unsigned len);
// Moves to +pos+ (clipped to the size); the new position, or -EIO.
int32_t wio_sd_seek(int h, uint32_t pos);
uint32_t wio_sd_tell(int h);
uint32_t wio_sd_size(int h);
#endif
