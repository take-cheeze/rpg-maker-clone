#include "profiler.hxx"

#include <mruby.h>
#include <mruby/hash.h>
#include <mruby/string.h>

#include <lvgl.h>

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <map>
#include <string>
#include <vector>

#if defined(__linux__)
#include <unistd.h>
#endif

namespace {

using clock_type = std::chrono::steady_clock;

uint64_t now_ns() {
  return static_cast<uint64_t>(
      std::chrono::duration_cast<std::chrono::nanoseconds>(
          clock_type::now().time_since_epoch())
          .count());
}

// ---- Configuration -------------------------------------------------------

bool g_enabled = false;
uint64_t g_interval_ns = 1'000'000'000ULL;  // 1s default

// ---- Allocation tracking (fed by profiler_allocf) ------------------------
//
// The game loop is single-threaded, so plain counters are enough. We only track
// call shape, not sizes: mruby's allocf does not hand us the previous size on
// realloc/free, and stashing a size header would break the 8-byte alignment
// mruby's word boxing depends on. `live` (outstanding blocks) and `calls`
// (cumulative allocations, used for an allocs/sec churn rate) are plenty to
// spot GC pressure.
profiler_allocf_t g_downstream_allocf = nullptr;
int64_t g_live_blocks = 0;
int64_t g_alloc_calls = 0;

// ---- Per-interval aggregation --------------------------------------------

struct FrameAgg {
  uint32_t frames = 0;
  double work_ns_sum = 0.0;  // CPU work: frame span minus reported idle
  double work_ns_max = 0.0;
  double period_ns_sum = 0.0;  // full frame span, including idle (drives fps)
};

struct SectionAgg {
  uint64_t calls = 0;
  double ns_sum = 0.0;
  double ns_max = 0.0;
};

FrameAgg g_frames;
std::map<std::string, SectionAgg> g_sections;

uint64_t g_frame_start = 0;       // now_ns() at the current frame_begin()
uint64_t g_frame_idle_ns = 0;     // idle reported within the current frame
uint64_t g_interval_start = 0;    // now_ns() when the interval opened
uint64_t g_alloc_calls_mark = 0;  // g_alloc_calls at interval start (for rate)
bool g_interval_open = false;

// ---- Chrome trace export (streamed) --------------------------------------

std::FILE* g_trace_file = nullptr;  // open while a trace is being recorded
bool g_trace_first = true;          // has any event been written yet (commas)
uint64_t g_trace_base_ns = 0;       // zero-point so timestamps start near 0

void reset_interval(uint64_t now) {
  g_frames = FrameAgg{};
  g_sections.clear();
  g_interval_start = now;
  g_alloc_calls_mark = g_alloc_calls;
  g_interval_open = true;
}

// ---- Memory probes -------------------------------------------------------

#if defined(__linux__)
size_t read_rss_bytes() {
  std::FILE* f = std::fopen("/proc/self/statm", "r");
  if (!f)
    return 0;
  long total = 0, resident = 0;
  const int got = std::fscanf(f, "%ld %ld", &total, &resident);
  std::fclose(f);
  if (got != 2)
    return 0;
  return static_cast<size_t>(resident) *
         static_cast<size_t>(sysconf(_SC_PAGESIZE));
}
#else
size_t read_rss_bytes() {
  return 0;
}
#endif

void append_bytes(std::string& s, char* buf, size_t buflen, double bytes) {
  std::snprintf(buf, buflen, "%.2fMB", bytes / (1024.0 * 1024.0));
  s += buf;
}

// ---- Chrome trace writers ------------------------------------------------

std::string json_escape(const char* s) {
  std::string o;
  for (const char* p = s; *p; ++p) {
    const unsigned char c = static_cast<unsigned char>(*p);
    switch (c) {
      case '"':
        o += "\\\"";
        break;
      case '\\':
        o += "\\\\";
        break;
      case '\n':
        o += "\\n";
        break;
      case '\r':
        o += "\\r";
        break;
      case '\t':
        o += "\\t";
        break;
      default:
        if (c < 0x20) {
          char b[8];
          std::snprintf(b, sizeof(b), "\\u%04x", c);
          o += b;
        } else {
          o += static_cast<char>(c);
        }
    }
  }
  return o;
}

// Timestamp in microseconds relative to the trace start, the unit Chrome's
// format expects.
double trace_us(uint64_t ns) {
  return static_cast<double>(ns - g_trace_base_ns) / 1000.0;
}

// Append one already-formatted JSON event object to the stream. Events are
// comma-separated; the trailing bracket is written by profiler_trace_stop(),
// and the format tolerates its absence so a truncated trace still loads.
void trace_raw(const std::string& ev) {
  if (!g_trace_file)
    return;
  if (!g_trace_first)
    std::fputc(',', g_trace_file);
  std::fputc('\n', g_trace_file);
  std::fwrite(ev.data(), 1, ev.size(), g_trace_file);
  g_trace_first = false;
}

// A complete ("X") duration event on the shared main-loop track (tid 1), so
// frames and sections nest into a flame chart. `args` is a pre-built JSON
// object body (may be empty).
void trace_complete(const char* name,
                    uint64_t start_ns,
                    uint64_t end_ns,
                    const std::string& args) {
  if (!g_trace_file)
    return;
  char num[96];
  std::string ev = "{\"ph\":\"X\",\"pid\":1,\"tid\":1,\"name\":\"";
  ev += json_escape(name);
  ev += "\"";
  std::snprintf(num, sizeof(num), ",\"ts\":%.3f,\"dur\":%.3f",
                trace_us(start_ns),
                static_cast<double>(end_ns - start_ns) / 1000.0);
  ev += num;
  if (!args.empty()) {
    ev += ",\"args\":{";
    ev += args;
    ev += "}";
  }
  ev += "}";
  trace_raw(ev);
}

// A counter ("C") event: `name` is the series group, `args` its named values.
void trace_counter(const char* name, uint64_t ns, const std::string& args) {
  if (!g_trace_file)
    return;
  char num[64];
  std::string ev = "{\"ph\":\"C\",\"pid\":1,\"name\":\"";
  ev += name;
  ev += "\"";
  std::snprintf(num, sizeof(num), ",\"ts\":%.3f", trace_us(ns));
  ev += num;
  ev += ",\"args\":{";
  ev += args;
  ev += "}}";
  trace_raw(ev);
}

// ---- Reporting -----------------------------------------------------------

// Format and print the interval summary to stderr, then open a fresh interval.
void report(uint64_t now) {
  const double secs = (now - g_interval_start) / 1e9;
  // fps from the measured frame period (span including idle), not the interval
  // wall-clock, so a partial frame at the interval edge doesn't skew it.
  const double avg_period_ms =
      g_frames.frames ? g_frames.period_ns_sum / g_frames.frames / 1e6 : 0.0;
  const double fps = avg_period_ms > 0 ? 1000.0 / avg_period_ms : 0.0;
  const double avg_ms =
      g_frames.frames ? g_frames.work_ns_sum / g_frames.frames / 1e6 : 0.0;
  const double max_ms = g_frames.work_ns_max / 1e6;

  std::string line = "[profiler] ";
  char buf[128];

  std::snprintf(buf, sizeof(buf),
                "fps=%.1f frame(work) avg=%.2fms max=%.2fms n=%u | mem rss=",
                fps, avg_ms, max_ms, g_frames.frames);
  line += buf;
  const double rss = static_cast<double>(read_rss_bytes());
  append_bytes(line, buf, sizeof(buf), rss);

  double lv_used = 0.0;
  unsigned lv_frag = 0;
  if (lv_is_initialized()) {
    lv_mem_monitor_t mon;
    lv_mem_monitor(&mon);
    lv_used = static_cast<double>(mon.total_size) -
              static_cast<double>(mon.free_size);
    lv_frag = mon.frag_pct;
  }
  line += " lv_used=";
  append_bytes(line, buf, sizeof(buf), lv_used);
  std::snprintf(buf, sizeof(buf), " lv_frag=%u%%", lv_frag);
  line += buf;

  const double alloc_rate =
      secs > 0 ? (g_alloc_calls - g_alloc_calls_mark) / secs : 0.0;
  std::snprintf(buf, sizeof(buf), " live_blocks=%lld allocs/s=%.0f",
                static_cast<long long>(g_live_blocks), alloc_rate);
  line += buf;

  // Sections, hottest first (by total time), capped so the line stays readable.
  std::vector<std::pair<std::string, SectionAgg>> secs_v(g_sections.begin(),
                                                         g_sections.end());
  std::sort(secs_v.begin(), secs_v.end(), [](const auto& a, const auto& b) {
    return a.second.ns_sum > b.second.ns_sum;
  });
  if (!secs_v.empty()) {
    line += " | sections:";
    const size_t top = std::min<size_t>(secs_v.size(), 8);
    for (size_t i = 0; i < top; ++i) {
      const SectionAgg& a = secs_v[i].second;
      const double s_avg = a.calls ? a.ns_sum / a.calls / 1e6 : 0.0;
      const double pct = g_frames.work_ns_sum > 0
                             ? a.ns_sum / g_frames.work_ns_sum * 100.0
                             : 0.0;
      std::snprintf(buf, sizeof(buf),
                    " %s avg=%.2fms max=%.2fms n=%llu (%.0f%%)",
                    secs_v[i].first.c_str(), s_avg, a.ns_max / 1e6,
                    static_cast<unsigned long long>(a.calls), pct);
      line += buf;
    }
  }

  std::fprintf(stderr, "%s\n", line.c_str());
  std::fflush(stderr);

  // Mirror the memory sample into the trace as counter series and flush the
  // stream so an interval's worth of events is durable if the process dies.
  if (g_trace_file) {
    char args[128];
    std::snprintf(args, sizeof(args), "\"rss_mb\":%.3f,\"lv_used_mb\":%.3f",
                  rss / (1024.0 * 1024.0), lv_used / (1024.0 * 1024.0));
    trace_counter("memory_mb", now, args);
    std::snprintf(args, sizeof(args), "\"live\":%lld",
                  static_cast<long long>(g_live_blocks));
    trace_counter("mruby_blocks", now, args);
    std::fflush(g_trace_file);
  }

  reset_interval(now);
}

}  // namespace

// ---- Public C++ API ------------------------------------------------------

void profiler_configure(bool enabled, int32_t interval_ms) {
  g_enabled = enabled;
  g_interval_ns =
      (interval_ms > 0 ? static_cast<uint64_t>(interval_ms) : 1000ULL) *
      1'000'000ULL;
}

bool profiler_enabled() {
  return g_enabled;
}

void profiler_trace_start(const char* path) {
  if (g_trace_file || path == nullptr || path[0] == '\0')
    return;
  g_trace_file = std::fopen(path, "w");
  if (!g_trace_file) {
    std::fprintf(stderr, "[profiler] could not open trace file: %s\n", path);
    return;
  }
  // Tracing is pointless without the timing it records, so turn it on.
  g_enabled = true;
  g_trace_first = true;
  g_trace_base_ns = now_ns();
  std::fputc('[', g_trace_file);
  trace_raw(
      "{\"ph\":\"M\",\"pid\":1,\"name\":\"process_name\",\"args\":"
      "{\"name\":\"rpg_maker_clone\"}}");
  trace_raw(
      "{\"ph\":\"M\",\"pid\":1,\"tid\":1,\"name\":\"thread_name\",\"args\":"
      "{\"name\":\"main loop\"}}");
  std::fflush(g_trace_file);
}

void profiler_trace_stop() {
  if (!g_trace_file)
    return;
  std::fputs("\n]\n", g_trace_file);
  std::fclose(g_trace_file);
  g_trace_file = nullptr;
}

bool profiler_tracing() {
  return g_trace_file != nullptr;
}

void profiler_set_downstream_allocf(profiler_allocf_t downstream) {
  g_downstream_allocf = downstream;
}

void* profiler_allocf(void* ptr, size_t size) {
  if (g_enabled) {
    ++g_alloc_calls;
    if (ptr == nullptr && size != 0)
      ++g_live_blocks;  // fresh allocation
    else if (size == 0 && ptr != nullptr)
      --g_live_blocks;  // free
    // realloc (ptr != null, size != 0) keeps the block count unchanged.
  }
  return g_downstream_allocf(ptr, size);
}

void profiler_frame_begin() {
  if (!g_enabled)
    return;
  const uint64_t now = now_ns();
  if (!g_interval_open)
    reset_interval(now);
  g_frame_start = now;
  g_frame_idle_ns = 0;
}

void profiler_note_idle(uint32_t idle_ms) {
  if (g_enabled)
    g_frame_idle_ns += static_cast<uint64_t>(idle_ms) * 1'000'000ULL;
}

void profiler_frame_end() {
  if (!g_enabled)
    return;
  const uint64_t now = now_ns();
  const double period = static_cast<double>(now - g_frame_start);
  double work = period - static_cast<double>(g_frame_idle_ns);
  if (work < 0.0)
    work = 0.0;  // guard against clock/idle rounding
  ++g_frames.frames;
  g_frames.work_ns_sum += work;
  g_frames.work_ns_max = std::max(g_frames.work_ns_max, work);
  g_frames.period_ns_sum += period;
  if (g_trace_file) {
    char args[48];
    std::snprintf(args, sizeof(args), "\"work_ms\":%.3f", work / 1e6);
    trace_complete("frame", g_frame_start, now, args);
  }
  if (now - g_interval_start >= g_interval_ns)
    report(now);
}

uint64_t profiler_section_begin() {
  return g_enabled ? now_ns() : 0;
}

void profiler_section_end(const char* name, uint64_t start) {
  if (!g_enabled || start == 0)
    return;
  const uint64_t end = now_ns();
  const double dur = static_cast<double>(end - start);
  SectionAgg& a = g_sections[name];
  ++a.calls;
  a.ns_sum += dur;
  a.ns_max = std::max(a.ns_max, dur);
  if (g_trace_file)
    trace_complete(name, start, end, std::string());
}

ProfilerScope::ProfilerScope(const char* name)
    : name_(name), start_(profiler_section_begin()) {}

ProfilerScope::~ProfilerScope() {
  profiler_section_end(name_, start_);
}

// ---- Ruby bindings: RGSS::Profiler ---------------------------------------

namespace {

mrb_value prof_enabled_p(mrb_state* M, mrb_value) {
  return mrb_bool_value(g_enabled);
}

mrb_value prof_set_enabled(mrb_state* M, mrb_value) {
  mrb_bool v;
  mrb_get_args(M, "b", &v);
  g_enabled = v;
  return mrb_bool_value(v);
}

// RGSS::Profiler.section("name") { ... } -- time the block under `name`. When
// profiling is off it just yields, so instrumentation can be left in place with
// no measurable cost.
mrb_value prof_section(mrb_state* M, mrb_value) {
  mrb_value name, blk;
  mrb_get_args(M, "S&", &name, &blk);
  if (mrb_nil_p(blk))
    return mrb_nil_value();
  if (!g_enabled)
    return mrb_yield_argv(M, blk, 0, nullptr);

  const uint64_t start = profiler_section_begin();
  const mrb_value ret = mrb_yield_argv(M, blk, 0, nullptr);
  // section_end copies the name into a stable std::string map key immediately,
  // so a transient c-string is fine here.
  profiler_section_end(mrb_string_value_cstr(M, &name), start);
  return ret;
}

// RGSS::Profiler.frame { ... } -- run one game-loop iteration as a profiled
// frame. Yields, timing the block as a frame (minus any idle Graphics.update
// reports). A plain yield when profiling is off.
mrb_value prof_frame(mrb_state* M, mrb_value) {
  mrb_value blk;
  mrb_get_args(M, "&", &blk);
  if (mrb_nil_p(blk))
    return mrb_nil_value();
  if (!g_enabled)
    return mrb_yield_argv(M, blk, 0, nullptr);

  profiler_frame_begin();
  const mrb_value ret = mrb_yield_argv(M, blk, 0, nullptr);
  profiler_frame_end();
  return ret;
}

// RGSS::Profiler.stats -- a Hash snapshot of the current interval so far, handy
// for tests and one-off measurement. Returns nil when profiling is disabled.
mrb_value prof_stats(mrb_state* M, mrb_value) {
  if (!g_enabled)
    return mrb_nil_value();

  const double avg_period_ms =
      g_frames.frames ? g_frames.period_ns_sum / g_frames.frames / 1e6 : 0.0;
  const double fps = avg_period_ms > 0 ? 1000.0 / avg_period_ms : 0.0;
  const double avg_ms =
      g_frames.frames ? g_frames.work_ns_sum / g_frames.frames / 1e6 : 0.0;

  mrb_value h = mrb_hash_new(M);
  mrb_hash_set(M, h, mrb_symbol_value(mrb_intern_lit(M, "frames")),
               mrb_fixnum_value(static_cast<mrb_int>(g_frames.frames)));
  mrb_hash_set(M, h, mrb_symbol_value(mrb_intern_lit(M, "fps")),
               mrb_float_value(M, fps));
  mrb_hash_set(M, h, mrb_symbol_value(mrb_intern_lit(M, "frame_avg_ms")),
               mrb_float_value(M, avg_ms));
  mrb_hash_set(M, h, mrb_symbol_value(mrb_intern_lit(M, "frame_max_ms")),
               mrb_float_value(M, g_frames.work_ns_max / 1e6));
  mrb_hash_set(M, h, mrb_symbol_value(mrb_intern_lit(M, "rss_bytes")),
               mrb_fixnum_value(static_cast<mrb_int>(read_rss_bytes())));
  mrb_hash_set(M, h, mrb_symbol_value(mrb_intern_lit(M, "live_blocks")),
               mrb_fixnum_value(static_cast<mrb_int>(g_live_blocks)));

  mrb_int lv_used = 0;
  if (lv_is_initialized()) {
    lv_mem_monitor_t mon;
    lv_mem_monitor(&mon);
    lv_used = static_cast<mrb_int>(mon.total_size - mon.free_size);
  }
  mrb_hash_set(M, h, mrb_symbol_value(mrb_intern_lit(M, "lv_used_bytes")),
               mrb_fixnum_value(lv_used));

  mrb_value sections = mrb_hash_new(M);
  for (const auto& kv : g_sections) {
    const SectionAgg& a = kv.second;
    mrb_value sh = mrb_hash_new(M);
    mrb_hash_set(M, sh, mrb_symbol_value(mrb_intern_lit(M, "calls")),
                 mrb_fixnum_value(static_cast<mrb_int>(a.calls)));
    mrb_hash_set(M, sh, mrb_symbol_value(mrb_intern_lit(M, "avg_ms")),
                 mrb_float_value(M, a.calls ? a.ns_sum / a.calls / 1e6 : 0.0));
    mrb_hash_set(M, sh, mrb_symbol_value(mrb_intern_lit(M, "max_ms")),
                 mrb_float_value(M, a.ns_max / 1e6));
    mrb_hash_set(M, sections, mrb_str_new(M, kv.first.data(), kv.first.size()),
                 sh);
  }
  mrb_hash_set(M, h, mrb_symbol_value(mrb_intern_lit(M, "sections")), sections);
  return h;
}

// RGSS::Profiler.report -- force the summary line out now and start a fresh
// interval.
mrb_value prof_report(mrb_state* M, mrb_value) {
  if (g_enabled && g_interval_open)
    report(now_ns());
  return mrb_nil_value();
}

// RGSS::Profiler.reset -- drop the current interval's samples.
mrb_value prof_reset(mrb_state* M, mrb_value) {
  if (g_enabled)
    reset_interval(now_ns());
  return mrb_nil_value();
}

// RGSS::Profiler.trace_start(path) -- begin streaming a Chrome trace to `path`
// (also enables profiling). Lets game code trace a specific window, e.g. one
// battle, rather than the whole run.
mrb_value prof_trace_start(mrb_state* M, mrb_value) {
  const char* path;
  mrb_get_args(M, "z", &path);
  profiler_trace_start(path);
  return mrb_bool_value(profiler_tracing());
}

// RGSS::Profiler.trace_stop -- finish and close the current trace.
mrb_value prof_trace_stop(mrb_state* M, mrb_value) {
  profiler_trace_stop();
  return mrb_nil_value();
}

mrb_value prof_tracing_p(mrb_state* M, mrb_value) {
  return mrb_bool_value(profiler_tracing());
}

}  // namespace

void profiler_init(mrb_state* M) {
  RClass* rgss = mrb_module_get(M, "RGSS");
  RClass* prof = mrb_define_module_under(M, rgss, "Profiler");
  mrb_define_module_function(M, prof, "enabled?", prof_enabled_p,
                             MRB_ARGS_NONE());
  mrb_define_module_function(M, prof, "enabled=", prof_set_enabled,
                             MRB_ARGS_REQ(1));
  mrb_define_module_function(M, prof, "section", prof_section,
                             MRB_ARGS_REQ(1) | MRB_ARGS_BLOCK());
  mrb_define_module_function(M, prof, "frame", prof_frame, MRB_ARGS_BLOCK());
  mrb_define_module_function(M, prof, "stats", prof_stats, MRB_ARGS_NONE());
  mrb_define_module_function(M, prof, "report", prof_report, MRB_ARGS_NONE());
  mrb_define_module_function(M, prof, "reset", prof_reset, MRB_ARGS_NONE());
  mrb_define_module_function(M, prof, "trace_start", prof_trace_start,
                             MRB_ARGS_REQ(1));
  mrb_define_module_function(M, prof, "trace_stop", prof_trace_stop,
                             MRB_ARGS_NONE());
  mrb_define_module_function(M, prof, "tracing?", prof_tracing_p,
                             MRB_ARGS_NONE());
}
