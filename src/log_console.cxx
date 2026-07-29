#include "log_console.hxx"

#include <cstddef>

#include <ng-log/logging.h>

#include "terminal.hxx"

namespace {

// Forwards each ng-log message into the terminal log console.  send() must be
// thread-safe (ng-log calls it from whichever thread ran the LOG() line) and
// must not itself log; terminal_console_push only touches a mutex-guarded ring
// buffer, so both hold.
class TerminalLogSink : public nglog::LogSink {
 public:
  void send(nglog::LogSeverity severity,
            const char* /*full_filename*/,
            const char* base_filename,
            int line,
            const nglog::LogMessageTime& /*time*/,
            const char* message,
            size_t message_len) override {
    terminal_console_push(static_cast<int>(severity), base_filename, line,
                          message, message_len);
  }
};

// The sink is registered with ng-log for the process lifetime, so give it
// static storage rather than leaking a heap allocation.
TerminalLogSink g_sink;

}  // namespace

void log_console_install() {
  nglog::AddLogSink(&g_sink);
}
