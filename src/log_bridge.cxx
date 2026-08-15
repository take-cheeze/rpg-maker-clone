#include "log_bridge.hxx"

#include <string_view>

#include <ng-log/logging.h>

#include "terminal.hxx"

namespace {

void forward_to_nglog(const char* msg, size_t len) {
  LOG(WARNING) << std::string_view(msg, len);
}

}  // namespace

void log_bridge_install() {
  log_bridge_set_hook(&forward_to_nglog);
}
