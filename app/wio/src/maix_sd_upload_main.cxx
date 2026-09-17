// Maix Amigo firmware: a temporary loader that writes files to the board's
// microSD card over USB-CDC serial, for a dev machine with no card reader
// to pull the card into. Not part of the port's roadmap -- it plays no role
// in running a game -- and not meant to stay flashed: run it, push game
// data with scripts/maix_sd_upload.py, then reflash maix_game (or whatever
// firmware you actually want running).
//
// Same top-level shape as app/wio/src/sd_upload_main.cxx (PING/PUT), but
// PUT's data phase is this board's own protocol -- see handle_put's
// comment for why (a K210-specific UARTHS quirk the Wio's UART doesn't
// have) -- so the two are not wire-compatible for that part:
//   PING\n                 -> "PONG SD_OK\n" or "PONG SD_FAIL\n"
//   PUT <path> <size>\n    -> "OK\n", then <size> decoded bytes in
//                             kChunk-sized pieces, each as 2*n lowercase
//                             hex chars immediately followed by a
//                             "CHUNK_OK\n" the host must wait for before
//                             sending the next piece (see handle_put),
//                             then "DONE <written>\n" or an
//                             "ERR <reason>\n" if the SD write failed
//                             partway.
//
// <path> has no spaces, so a single space-split is enough; there is no
// wildcard/recursive anything here.
//
// Lives under app/wio/src/ only because platformio.ini sets a single,
// project-wide `src_dir` (see maix_amigo_main.cxx's own comment for why).

#include <Arduino.h>

#include "maix_tf_sd.h"

namespace {

bool g_sd_ok = false;

// Reads one '\n'-terminated line (line does not include the '\n'). Blocks
// until a line arrives -- this loader has nothing else to do meanwhile.
String read_line() {
  String line;
  for (;;) {
    while (!Serial.available()) {
    }
    const char c = (char)Serial.read();
    if (c == '\n')
      return line;
    if (c != '\r')
      line += c;
  }
}

// Splits "<path> <size>" from a PUT line's remainder.
bool parse_put(const String& rest, String* path, uint32_t* size) {
  const int sp = rest.indexOf(' ');
  if (sp < 0)
    return false;
  *path = rest.substring(0, sp);
  *size = (uint32_t)rest.substring(sp + 1).toInt();
  return true;
}

// Ensures every ancestor directory of `path` exists. sdfat's mkdir makes
// one level only and fails when the parent is missing too, so walk down
// from the root creating each level ("/a/b/file" creates "/a" then "/a/b").
//
// NOTE: this stays inline in the existing function on purpose. A revision
// that factored the strip/loop into separate helpers produced an image
// that never prints anything on real hardware (no beacon, no PING reply),
// even though the helpers only run on PUT -- some codegen/layout
// sensitivity in this toolchain, cause unknown. If you refactor this,
// re-verify on the board, not just in CI.
void ensure_parent_dir(const String& path) {
  int start = 0;
  for (;;) {
    const int slash = path.indexOf('/', start);
    if (slash < 0)
      return;
    if (slash > 0) {
      const String dir = path.substring(0, slash);
      if (!maix_tf_sd().exists(dir))
        maix_tf_sd().mkdir(dir);
    }
    start = slash + 1;
  }
}

void handle_put(const String& rest) {
  String path;
  uint32_t size;
  if (!parse_put(rest, &path, &size)) {
    Serial.println("ERR bad PUT");
    return;
  }
  if (!g_sd_ok) {
    Serial.println("ERR no SD");
    return;
  }

  // The game addresses SD content under GAME_DIR "/sd/<game>" but the SD
  // library roots at "/": strip a leading "/sd", mirroring
  // maix_sd_syscalls.cxx's to_sd_path, so uploads land where the game
  // looks for them.
  if (path.startsWith("/sd/"))
    path = path.substring(3);
  ensure_parent_dir(path);
  // Truncate any partial retry: FILE_WRITE appends, so a previous short
  // read would otherwise leave a corrupt over-long file behind.
  maix_tf_sd().remove(path.c_str());
  File f = maix_tf_sd().open(path.c_str(), FILE_WRITE);
  if (!f) {
    Serial.println("ERR open failed");
    return;
  }

  Serial.println("OK");

  // The host hex-encodes the payload (two lowercase chars per byte): the
  // framework's UARTHS receive ISR drops 0x00 bytes outright
  // (`if (data != 0)` in uarths_rec_callback), so raw binary can never
  // arrive intact. Hex keeps every wire byte printable and non-zero; the
  // nibble math stays inline below (see ensure_parent_dir's note about
  // keeping this TU's shape).
  //
  // Two nested chunk sizes, for two different reasons:
  //  - kSubChunk (64 decoded bytes, 128 hex chars): the biggest single
  //    Serial.readBytes() this UART's RX path can be trusted with.
  //    RingBuffer.h's RING_BUFFER_SIZE is 64, and Serial.readBytes()
  //    itself polls continuously while it fills that one call's target
  //    length, so this is about *this* call finishing before anything
  //    outside the read loop (i.e. the f.write() below) stops draining
  //    the ring buffer -- unrelated to kChunk's size.
  //  - kChunk (2048 decoded bytes): how much accumulates in `accum`
  //    across repeated kSubChunk reads -- during which the ring buffer
  //    keeps draining continuously, no stall -- before one f.write()
  //    call, which *does* stop draining for as long as the SD card
  //    takes. A CHUNK_OK the host waits for after every kChunk paces the
  //    transfer around exactly that stall, instead of a host-side sleep
  //    guessed to outlast it (the previous version of this loop, one
  //    f.write() per kSubChunk with a blind 50ms host-side sleep after
  //    each -- correct, but the dominant cost of any transfer of
  //    meaningful size: ~50ms x size/64, hours for a real game).
  constexpr uint32_t kSubChunk = 64;
  constexpr uint32_t kChunk = 2048;
  uint8_t wire[kSubChunk * 2];
  uint8_t accum[kChunk];
  uint32_t remaining = size;
  uint32_t written = 0;
  bool timed_out = false;
  while (remaining > 0 && !timed_out) {
    uint32_t chunk_got = 0;
    while (chunk_got < kChunk && remaining > 0) {
      const uint32_t want = remaining > kSubChunk ? kSubChunk : remaining;
      const size_t got = Serial.readBytes((char*)wire, want * 2);
      if (got < want * 2) {
        timed_out = true;  // host went quiet past the serial timeout
        break;
      }
      for (uint32_t i = 0; i < want; ++i) {
        const uint8_t hi =
            wire[2 * i] <= '9' ? wire[2 * i] - '0' : wire[2 * i] - 'a' + 10;
        const uint8_t lo = wire[2 * i + 1] <= '9' ? wire[2 * i + 1] - '0'
                                                  : wire[2 * i + 1] - 'a' + 10;
        accum[chunk_got + i] = (uint8_t)((hi << 4) | lo);
      }
      chunk_got += want;
      remaining -= want;
    }
    if (chunk_got == 0)
      break;
    written += f.write(accum, chunk_got);
    if (remaining > 0 && !timed_out)
      Serial.println("CHUNK_OK");
  }
  f.close();

  if (remaining > 0)
    Serial.println("ERR short read");
  else
    Serial.print(String("DONE ") + written + "\n");
}

}  // namespace

void setup(void) {
  // Higher than the console/game firmwares' 115200: this loader's only
  // job is bulk transfer (PUT bodies are hex-encoded raw bytes -- see the
  // file header comment -- so wire time already doubles the real
  // payload size), and UARTHSClass::begin() programs the K210's UARTHS
  // divider directly from whatever rate is passed (uarths_config in the
  // Kendryte SDK), not a fixed table -- kflash's own upload already runs
  // well above 115200 on this same USB-serial bridge (its "Programming
  // BIN" throughput implies a comparable rate), so this is a proven-safe
  // rate for this specific hardware, not a guess. Pair with a matching
  // --baud on the host side (scripts/maix_sd_upload.py's default).
  Serial.begin(1500000);
  Serial.setTimeout(5000);
  // TF slot: SPI0 on pins 11/6/10, chip-select 26 -- see maix_tf_sd.h for
  // why the library's global `SD` (SPI1, wrong pins) cannot be used here.
  g_sd_ok = maix_tf_sd().begin(26);
  Serial.println(g_sd_ok ? "MAIX-UPLOADER READY SD_OK"
                         : "MAIX-UPLOADER READY SD_FAIL");
}

void loop(void) {
  const String line = read_line();
  if (line == "PING")
    Serial.println(g_sd_ok ? "PONG SD_OK" : "PONG SD_FAIL");
  else if (line.startsWith("PUT "))
    handle_put(line.substring(4));
  else if (line.length() > 0)
    Serial.println("ERR unknown command");
}
