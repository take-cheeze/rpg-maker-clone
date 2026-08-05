#pragma once

#include <string>

#include <mruby.h>

// One copy-pasteable crash report.
//
// When the engine dies on an mruby exception it used to print the class, the
// message and mruby's own backtrace and quit. That is enough for whoever is
// sitting at a terminal and nowhere near enough for a bug report: it says
// nothing about which build, which project or which runtime log lines led up to
// it, and in the browser it is buried in a collapsed panel. So every fatal path
// now goes through error_dump_report, which assembles all of that into one
// Markdown block a player can hand over as-is.
//
// The block is printed to stderr between the markers below, written to the
// --error_dump file, and -- in the browser, where there is no terminal to copy
// from -- scraped off the log by the shell page (src/shell.html), which offers
// it as "Copy error report".

// Fence the report so a reader (the shell page, or a human scrolling a log)
// can tell exactly where it starts and ends. Keep these in sync with the
// matching strings in src/shell.html.
constexpr char ERROR_DUMP_BEGIN[] =
    "----- BEGIN RPG MAKER CLONE ERROR REPORT -----";
constexpr char ERROR_DUMP_END[] =
    "----- END RPG MAKER CLONE ERROR REPORT -----";

// Record a fact about this run for the report's "Run" section: the game
// directory, the detected project type, the window size. Facts appear in the
// order first set; setting a key again replaces its value.
void error_dump_set_context(const char* key, const std::string& value);

// Start capturing the runtime log (RGSS::ErrorReport.install, see
// mruby-rgss/mrblib/error_report.rb) so a report can carry the messages that
// preceded the failure. Call once, right after the interpreter is opened. A
// no-op when the gem is absent (the standalone mruby test binary).
void error_dump_install(mrb_state* M);

// Report the exception pending on M -- print it between the markers, write the
// --error_dump file and hand the text back -- then clear it. Returns an empty
// string when nothing was pending, so this is safe to call on any bail-out
// path. `where` names the engine site that caught it ("the frame loop", ...).
std::string error_dump_report(mrb_state* M, const char* where);

// Raise a real exception and read the resulting report back, checking it kept
// the message, the backtrace and the captured log. Returns EXIT_SUCCESS /
// EXIT_FAILURE; drives --error_dump_probe and the error_dump ctest.
int error_dump_run_probe(mrb_state* M);
