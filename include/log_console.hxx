#pragma once

// Install an nglog::LogSink that forwards every log message into the terminal
// log console (see terminal_console_push in terminal.hxx).  Call this once,
// after nglog::InitializeLogging, when a terminal backend (--sixel/--iterm) is
// active and the console is enabled.  Lives in the executable rather than the
// mruby-rgss gem so the gem keeps no compile-time dependency on ng-log.
void log_console_install();
