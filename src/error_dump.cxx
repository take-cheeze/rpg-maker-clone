// Crash reporting: turn a fatal mruby exception into one copy-pasteable block.
// See include/error_dump.hxx for what this is for and how the browser shell
// picks the block up.

#include "error_dump.hxx"

#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <iterator>
#include <string>
#include <utility>
#include <vector>

#include <mruby/array.h>
#include <mruby/class.h>
#include <mruby/string.h>
#include <mruby/variable.h>
#include <mruby/version.h>

#include <gflags/gflags.h>

// Stamped in by the build (see CMakeLists.txt). Defaulted so the file still
// compiles in a build that does not define them.
#ifndef RPG_BUILD_REVISION
#define RPG_BUILD_REVISION "unknown"
#endif
#ifndef RPG_BUILD_TYPE
#define RPG_BUILD_TYPE "unknown"
#endif

DEFINE_string(
    error_dump,
    "error-report.md",
    "Write the crash report to this file (relative paths resolve against the "
    "working directory) when the engine dies on a Ruby exception, so it can be "
    "attached to a bug report. The same text is always printed to stderr. Pass "
    "an empty value to write no file. Ignored in the browser build, where the "
    "page offers the report for copy/download instead");

namespace {

std::vector<std::pair<std::string, std::string>>& context() {
  static std::vector<std::pair<std::string, std::string>> ctx;
  return ctx;
}

const char* platform_name() {
#if defined(__EMSCRIPTEN__)
  return "WebAssembly (browser)";
#elif defined(_WIN32)
  return "Windows";
#elif defined(__APPLE__)
  return "macOS";
#elif defined(__linux__)
  return "Linux";
#else
  return "unknown";
#endif
}

std::string to_std_string(mrb_value v) {
  if (!mrb_string_p(v))
    return std::string();
  return std::string(RSTRING_PTR(v), static_cast<size_t>(RSTRING_LEN(v)));
}

// mrb_funcall on a VM that just died can raise again (a broken #message, a
// missing method); a report is worth having even then, so swallow that second
// failure and answer nil. The caller must have cleared mrb->exc first --
// mruby refuses to run with one pending.
mrb_value call(mrb_state* M, mrb_value recv, const char* name) {
  const mrb_value v = mrb_funcall(M, recv, name, 0);
  if (M->exc) {
    M->exc = nullptr;
    return mrb_nil_value();
  }
  return v;
}

// The constant `name` under `owner`, or nil when it is not defined. Asking
// mrb_const_get for a missing constant raises, which is exactly what a report
// path must not do.
mrb_value const_or_nil(mrb_state* M, mrb_value owner, const char* name) {
  if (!mrb_class_p(owner) && !mrb_module_p(owner))
    return mrb_nil_value();
  const mrb_sym sym = mrb_intern_cstr(M, name);
  if (!mrb_const_defined(M, owner, sym))
    return mrb_nil_value();
  return mrb_const_get(M, owner, sym);
}

mrb_value error_report_module(mrb_state* M) {
  const mrb_value rgss =
      const_or_nil(M, mrb_obj_value(M->object_class), "RGSS");
  return const_or_nil(M, rgss, "ErrorReport");
}

// The tail of the runtime log, as RGSS::ErrorReport recorded it. Empty when the
// gem is absent or nothing was logged.
std::string runtime_log_tail(mrb_state* M) {
  if (M == nullptr)
    return std::string();
  const mrb_value mod = error_report_module(M);
  if (mrb_nil_p(mod))
    return std::string();
  return to_std_string(call(M, mod, "log_tail"));
}

void append_fenced(std::string& out, const std::string& body) {
  out += "```\n";
  out += body;
  if (body.empty() || body[body.size() - 1] != '\n')
    out += "\n";
  out += "```\n\n";
}

std::string build(mrb_state* M, mrb_value exc, const char* where) {
  std::string r;
  r += "# RPG Maker Clone error report\n\n";
  r += "The engine stopped with an error. Paste this whole block into the bug "
       "report -- it is what the maintainers need to place the failure.\n\n";

  r += "## Build\n\n";
  r += "- revision: " RPG_BUILD_REVISION
       " (stamped when the build was "
       "configured)\n";
  r += "- build type: " RPG_BUILD_TYPE "\n";
  r += std::string("- platform: ") + platform_name() + " (" +
       std::to_string(sizeof(void*) * 8) + "-bit)\n";
  r += "- mruby: " MRUBY_VERSION "\n\n";

  r += "## Run\n\n";
  r += std::string("- caught at: ") + (where ? where : "(unspecified)") + "\n";
  for (const auto& kv : context())
    r += "- " + kv.first + ": " + kv.second + "\n";
  r += "\n";

  r += "## Error\n\n";
  if (M == nullptr || mrb_nil_p(exc)) {
    r += "No Ruby exception was pending; see the log below.\n\n";
  } else {
    const std::string cls = mrb_obj_classname(M, exc);
    append_fenced(r, cls + ": " + to_std_string(call(M, exc, "message")));

    // mruby's own printer walks the backtrace from the outermost frame to the
    // innermost, which is where the exception was actually raised; keep that
    // order so a report reads like the trace people already know.
    const mrb_value bt = call(M, exc, "backtrace");
    if (mrb_array_p(bt) && RARRAY_LEN(bt) > 0) {
      std::string trace = "trace (most recent call last):\n";
      for (mrb_int i = RARRAY_LEN(bt) - 1; i >= 0; --i)
        trace += "\t" + to_std_string(RARRAY_PTR(bt)[i]) + "\n";
      r += "### Backtrace\n\n";
      append_fenced(r, trace);
    } else {
      // mruby drops every frame whose bytecode carries no debug info, so an
      // empty backtrace means the failing code was compiled without it rather
      // than that the exception came from nowhere. Say which, so a report
      // arriving without a trace is not mistaken for one that lost it.
      r += "### Backtrace\n\nNot available (the failing code was compiled "
           "without debug info).\n\n";
    }
  }

  const std::string log = runtime_log_tail(M);
  if (!log.empty()) {
    r += "## Recent log\n\n";
    append_fenced(r, log);
  }
  return r;
}

bool write_report_file(const std::string& report, std::string* path_out) {
#ifdef __EMSCRIPTEN__
  // The browser filesystem is a throwaway in-memory tree, so a file there
  // reaches nobody; the page hands the report over instead (src/shell.html).
  (void)report;
  (void)path_out;
  return false;
#else
  if (FLAGS_error_dump.empty())
    return false;
  std::ofstream out(FLAGS_error_dump.c_str(),
                    std::ios::binary | std::ios::trunc);
  if (!out)
    return false;
  out << report;
  out.close();
  if (!out)
    return false;
  *path_out = FLAGS_error_dump;
  return true;
#endif
}

}  // namespace

void error_dump_set_context(const char* key, const std::string& value) {
  for (auto& kv : context()) {
    if (kv.first == key) {
      kv.second = value;
      return;
    }
  }
  context().emplace_back(key, value);
}

void error_dump_install(mrb_state* M) {
  if (M == nullptr)
    return;
  const int ai = mrb_gc_arena_save(M);
  const mrb_value mod = error_report_module(M);
  if (!mrb_nil_p(mod))
    call(M, mod, "install");
  mrb_gc_arena_restore(M, ai);
}

std::string error_dump_report(mrb_state* M, const char* where) {
  if (M == nullptr || M->exc == nullptr)
    return std::string();

  // Building the report calls back into Ruby (#message, #backtrace, the log
  // tail), which mruby will not do with an exception pending -- so clear it,
  // and keep the object alive through the arena while it is no longer the VM's.
  const mrb_value exc = mrb_obj_value(M->exc);
  const int ai = mrb_gc_arena_save(M);
  M->exc = nullptr;
  mrb_gc_protect(M, exc);

  const std::string report = build(M, exc, where);

  M->exc = nullptr;
  mrb_gc_arena_restore(M, ai);

  std::fprintf(stderr, "%s\n%s%s\n", ERROR_DUMP_BEGIN, report.c_str(),
               ERROR_DUMP_END);
  std::string path;
  if (write_report_file(report, &path))
    std::fprintf(stderr, "[ErrorDump] report written to %s\n", path.c_str());
  std::fflush(stderr);
  return report;
}

int error_dump_run_probe(mrb_state* M) {
  const mrb_value mod = error_report_module(M);
  if (mrb_nil_p(mod)) {
    std::fprintf(stderr,
                 "[ErrorDump-PROBE] FAIL RGSS::ErrorReport is not defined\n");
    return EXIT_FAILURE;
  }
  const std::string log_line =
      to_std_string(const_or_nil(M, mod, "PROBE_LOG_LINE"));
  const std::string message =
      to_std_string(const_or_nil(M, mod, "PROBE_MESSAGE"));

  mrb_funcall(M, mod, "probe!", 0);
  if (M->exc == nullptr) {
    std::fprintf(stderr, "[ErrorDump-PROBE] FAIL the probe did not raise\n");
    return EXIT_FAILURE;
  }

  const std::string report = error_dump_report(M, "the error-dump probe");

  struct Check {
    const char* what;
    std::string needle;
  };
  const Check checks[] = {
      // The exception itself, class and message both.
      {"the exception", "RuntimeError: " + message},
      // The backtrace: probe! raises from a second method, so a trace that
      // survived the report carries both frames.
      {"the backtrace", "trace (most recent call last):"},
      {"the raising frame", "probe_raise"},
      // The runtime log the tee captured before the raise -- the part of a
      // report that is easiest to lose and hardest to notice missing.
      {"the captured log", log_line},
      {"the run context", "- caught at: the error-dump probe"},
  };

  bool ok = true;
  for (const Check& c : checks) {
    if (c.needle.empty() || report.find(c.needle) == std::string::npos) {
      std::fprintf(stderr, "[ErrorDump-PROBE] FAIL the report is missing %s\n",
                   c.what);
      ok = false;
    }
  }

#ifndef __EMSCRIPTEN__
  // The file a reporter attaches must hold the same text that was printed.
  if (!FLAGS_error_dump.empty()) {
    std::ifstream in(FLAGS_error_dump.c_str(), std::ios::binary);
    const std::string written((std::istreambuf_iterator<char>(in)),
                              std::istreambuf_iterator<char>());
    if (written != report) {
      std::fprintf(stderr,
                   "[ErrorDump-PROBE] FAIL %s does not hold the printed "
                   "report\n",
                   FLAGS_error_dump.c_str());
      ok = false;
    }
    in.close();
    std::remove(FLAGS_error_dump.c_str());
  }
#endif

  std::fprintf(stderr, "[ErrorDump-PROBE] %s\n", ok ? "ok" : "failed");
  return ok ? EXIT_SUCCESS : EXIT_FAILURE;
}
