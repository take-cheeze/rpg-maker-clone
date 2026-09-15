// Maix Amigo firmware: a temporary loader that writes files to the board's
// microSD card over USB-CDC serial, for a dev machine with no card reader
// to pull the card into. Not part of the port's roadmap -- it plays no role
// in running a game -- and not meant to stay flashed: run it, push game
// data with scripts/maix_sd_upload.py, then reflash maix_game (or whatever
// firmware you actually want running).
//
// Same line protocol as app/wio/src/sd_upload_main.cxx (deliberately: the
// host scripts speak identically, only defaults differ), one request at a
// time:
//   PING\n                 -> "PONG SD_OK\n" or "PONG SD_FAIL\n"
//   PUT <path> <size>\n    -> "OK\n", then reads exactly <size> decoded
//                             bytes as 2*<size> lowercase hex chars (raw
//                             binary cannot go over the wire: the
//                             framework's UARTHS ISR drops 0x00) and writes
//                             them to <path> (parent dirs made if missing,
//                             any partial retry truncated), then
//                             "DONE <written>\n" or an "ERR <reason>\n" if
//                             the SD write failed partway.
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
  uint8_t wire[128];
  uint8_t dec[64];
  uint32_t remaining = size;
  uint32_t written = 0;
  while (remaining > 0) {
    // Small wire bulks, decoded then written in one go: the UARTHS
    // receive ISR reads a single byte per interrupt, so a long
    // uninterrupted burst overruns the hardware FIFO (observed past
    // ~64 bytes); the host paces its chunks and this side never stalls
    // mid-bulk on an SD write.
    const uint32_t want = remaining > 64 ? 64 : remaining;
    const size_t got = Serial.readBytes((char*)wire, want * 2);
    if (got < want * 2)
      break;  // host went quiet past the serial timeout -- give up
    for (uint32_t i = 0; i < want; ++i) {
      const uint8_t hi =
          wire[2 * i] <= '9' ? wire[2 * i] - '0' : wire[2 * i] - 'a' + 10;
      const uint8_t lo = wire[2 * i + 1] <= '9' ? wire[2 * i + 1] - '0'
                                                : wire[2 * i + 1] - 'a' + 10;
      dec[i] = (uint8_t)((hi << 4) | lo);
    }
    written += f.write(dec, want);
    remaining -= want;
  }
  f.close();

  if (remaining > 0)
    Serial.println("ERR short read");
  else
    Serial.print(String("DONE ") + written + "\n");
}

}  // namespace

void setup(void) {
  Serial.begin(115200);
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
