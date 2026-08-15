#include "log_bridge.hxx"

#include <string_view>

#include <ng-log/logging.h>

#include "terminal.hxx"

namespace {

// `file`/`line` are where the message really came from -- the Ruby script
// location for a line written by a game's own script or by the engine's Ruby
// half (see include/terminal.hxx's "Stderr log bridge" section).  Handing them
// to nglog::LogMessage, rather than using LOG(WARNING) here, is what makes the
// log (and the on-screen console fed by src/log_console.cxx) say
// "Scene_Map:120" instead of stamping every bridged line with this file and
// this line number.  A null `file` means the caller had no location to give --
// the native log_bridge_write_stderr diagnostics, or bytecode built without
// debug info -- and those keep the old behaviour of pointing here.
void forward_to_nglog(const char* msg, size_t len, const char* file, int line) {
  if (file == nullptr) {
    LOG(WARNING) << std::string_view(msg, len);
    return;
  }
  nglog::LogMessage(file, line, nglog::NGLOG_WARNING).stream()
      << std::string_view(msg, len);
}

}  // namespace

void log_bridge_install() {
  log_bridge_set_hook(&forward_to_nglog);
}
