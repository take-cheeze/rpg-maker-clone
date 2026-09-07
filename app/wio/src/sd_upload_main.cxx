// Wio Terminal firmware: a temporary loader that writes files to the
// board's microSD card over the same USB-CDC serial connection used for
// flashing, for dev machines with no card reader to pull the card into.
// Not part of the port's roadmap (docs/adr/0007) -- it plays no role in
// running a game -- and not meant to stay flashed: run it, push the exported
// map with scripts/wio_sd_upload.py, then reflash wio_walk or wio.
//
// Line protocol over Serial, one request at a time:
//   PING\n                 -> "PONG SD_OK\n" or "PONG SD_FAIL\n"
//   PUT <path> <size>\n    -> "OK\n", then reads exactly <size> raw bytes
//                             and writes them to <path> (parent dir made if
//                             missing), then "DONE <written>\n" or an
//                             "ERR <reason>\n" if the SD write failed partway.
//
// <path> has no spaces (the two files this exists to push don't), so a
// single space-split is enough; there is no wildcard/recursive anything here.

#include <Arduino.h>
#include <SPI.h>
#include <Seeed_FS.h>

#include "SD/Seeed_SD.h"

#ifndef SDCARD_SS_PIN
#define SDCARD_SS_PIN 1
#endif
#ifndef SDCARD_SPI
#define SDCARD_SPI SPI
#endif

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

// Ensures the single parent directory in `path` exists (this loader's paths
// are always "/one/dir/file", never deeper).
void ensure_parent_dir(const String& path) {
  const int slash = path.lastIndexOf('/');
  if (slash <= 0)
    return;
  const String dir = path.substring(0, slash);
  if (!SD.exists(dir))
    SD.mkdir(dir);
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

  ensure_parent_dir(path);
  File f = SD.open(path.c_str(), FILE_WRITE);
  if (!f) {
    Serial.println("ERR open failed");
    return;
  }

  Serial.println("OK");

  uint8_t buf[512];
  uint32_t remaining = size;
  uint32_t written = 0;
  while (remaining > 0) {
    const size_t chunk = remaining < sizeof(buf) ? remaining : sizeof(buf);
    const size_t got = Serial.readBytes((char*)buf, chunk);
    if (got == 0)
      break;  // host went quiet past the serial timeout -- give up
    written += f.write(buf, got);
    remaining -= (uint32_t)got;
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
  g_sd_ok = SD.begin(SDCARD_SS_PIN, SDCARD_SPI);
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
