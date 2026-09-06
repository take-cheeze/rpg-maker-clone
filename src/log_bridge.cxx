#include "log_bridge.hxx"

#include <string_view>

#include <ng-log/flags.h>
#include <ng-log/logging.h>

#include "terminal.hxx"

namespace {

// Every line reaching this hook was already written to the real `$stderr` a
// moment ago by RGSS::ErrorReport's Tee (mruby-rgss/mrblib/error_report.rb),
// which is the bridge's only caller -- see include/terminal.hxx's "Stderr log
// bridge" section. Logging it again at nglog::NGLOG_WARNING would print the
// same text a second time wherever ng-log would otherwise also copy it to
// stderr itself: not just --stderrthreshold at or below WARNING (e.g. the
// Emscripten build raises it in main.cxx so native, non-bridged warnings
// still reach the page), but also --logtostderr/--alsologtostderr, which
// bypass the threshold entirely and are not just command-line flags -- ng-log
// reads them (as GLOG_logtostderr / GLOG_alsologtostderr, its old name from
// before the ng-log rename) from the environment, and flake.nix's dev shell
// sets exactly that for its own purpose (CTest output on stderr), enabling it
// for every build run from that shell too. Forcing all three flags to their
// quietest setting for the duration of this one message keeps it going to
// the log file and the on-screen console sink (src/log_console.cxx) exactly
// as before, just without the redundant stderr copy. The flags are guarded
// by nglog's own internal log_mutex only while a message is actually being
// written, not while merely being read or assigned here, so a message from
// another thread landing in that narrow window can miss its own stderr copy
// (still reaches the file/console); a cosmetic, rare race, not a correctness
// issue.
void log_at_warning_without_stderr_echo(const char* file,
                                        int line,
                                        const char* msg,
                                        size_t len) {
  const bool saved_logtostderr = FLAGS_logtostderr;
  const bool saved_alsologtostderr = FLAGS_alsologtostderr;
  const nglog::int32 saved_stderr_threshold = FLAGS_stderrthreshold;
  FLAGS_logtostderr = false;
  FLAGS_alsologtostderr = false;
  FLAGS_stderrthreshold = nglog::NGLOG_FATAL;
  nglog::LogMessage(file, line, nglog::NGLOG_WARNING).stream()
      << std::string_view(msg, len);
  FLAGS_logtostderr = saved_logtostderr;
  FLAGS_alsologtostderr = saved_alsologtostderr;
  FLAGS_stderrthreshold = saved_stderr_threshold;
}

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
  log_at_warning_without_stderr_echo(file ? file : __FILE__,
                                     file ? line : __LINE__, msg, len);
}

}  // namespace

void log_bridge_install() {
  log_bridge_set_hook(&forward_to_nglog);
}
