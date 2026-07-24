#pragma once

#include <cstddef>
#include <cstdint>

// Forward declaration to avoid pulling <mruby.h> into every includer.
struct mrb_state;

// A lightweight, always-linked performance profiler for the game loop. It
// measures per-frame CPU time and named sub-sections (the "where does the frame
// go" bottleneck breakdown) and samples memory use (process RSS, the LVGL heap
// pool and mruby allocation activity), then prints a one-line summary to stderr
// about once per reporting interval.
//
// The whole subsystem is inert until profiler_configure() enables it, so the
// default (unprofiled) build pays only a single predicted branch per frame and
// per section. Enabled from main() via the --profile flag.

// Type of an allocator function, matching mruby 4.0's global
// mrb_basic_alloc_func (ptr, size) contract: size 0 frees, a non-null ptr
// reallocs, otherwise it allocates. Kept here so main() can hand its allocator
// to the profiler without including <mruby.h> from the profiler header.
using profiler_allocf_t = void* (*)(void*, size_t);

// Enable profiling and set how often (in milliseconds) a summary line is
// emitted. Call once from main() after flag parsing and, so the allocator hook
// observes the right state, before mruby is opened. A non-positive
// interval_ms falls back to 1000ms.
void profiler_configure(bool enabled, int32_t interval_ms);

// Whether profiling is currently enabled.
bool profiler_enabled();

// Allocation-tracking hook. Have mruby's global allocator
// (mrb_basic_alloc_func) call it and register the real allocator as the
// downstream via profiler_set_downstream_allocf(): the hook counts allocation
// activity and forwards every call unchanged. Safe to leave installed when
// disabled -- it then only forwards. Do NOT use under a build that keeps
// mruby's default allocator (e.g. Emscripten); there the hook is simply never
// installed and memory stats fall back to the LVGL pool monitor.
void profiler_set_downstream_allocf(profiler_allocf_t downstream);
void* profiler_allocf(void* ptr, size_t size);

// Game-loop frame boundaries. A frame spans one main_loop iteration and is
// driven from Ruby via RGSS::Profiler.frame { ... }, which calls frame_begin()
// before the iteration and frame_end() after it. frame_end() records the
// frame's "work" time -- the wall-clock span minus any idle reported through
// profiler_note_idle() -- and, once per interval, prints the summary line.
void profiler_frame_begin();
void profiler_frame_end();

// Report an idle wait (in milliseconds) that happened inside the current frame,
// e.g. the fps-cap sleep in Graphics.update. Subtracted from the frame's work
// time so the profiler reports CPU cost rather than time spent sleeping.
void profiler_note_idle(uint32_t idle_ms);

// Named-section timing primitives. profiler_section_begin() returns an opaque
// start stamp to hand back to profiler_section_end(); the elapsed time is
// aggregated under `name` for the current interval. `name` must outlive the
// call (a string literal is ideal). No-ops when profiling is disabled.
uint64_t profiler_section_begin();
void profiler_section_end(const char* name, uint64_t start);

// RAII helper that times the enclosing C++ scope as section `name`.
class ProfilerScope {
 public:
  explicit ProfilerScope(const char* name);
  ~ProfilerScope();

  ProfilerScope(const ProfilerScope&) = delete;
  ProfilerScope& operator=(const ProfilerScope&) = delete;

 private:
  const char* name_;
  uint64_t start_;
};

// Chrome trace export. When a trace is open, every frame and named section is
// streamed to `path` as a Chrome Trace Event ("X" duration) event and the
// periodic memory sample as counter ("C") events, forming a file that
// chrome://tracing and https://ui.perfetto.dev load directly. Frames and
// sections share one thread track so they nest into a flame chart.
//
// Starting a trace also enables profiling (there is nothing to record
// otherwise). The stream is flushed each interval and closed by
// profiler_trace_stop(); the format tolerates a missing closing bracket, so a
// trace is still loadable if the process dies mid-run. Starting a trace while
// one is already open is a no-op. Safe to call with an empty/null path (no-op).
void profiler_trace_start(const char* path);
void profiler_trace_stop();
bool profiler_tracing();

// Register the RGSS::Profiler Ruby module and its methods. Called from the
// mruby-rgss gem init.
void profiler_init(mrb_state* mrb);
