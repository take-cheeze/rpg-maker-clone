#include "terminal.hxx"

#include "profiler.hxx"

#include <atomic>
#include <cerrno>
#include <condition_variable>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <deque>
#include <mutex>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>

#include <lvgl.h>
#include <mruby.h>
#include <mruby/class.h>
#include <mruby/value.h>

namespace {

// RGSS::Input key ids (mirrors mruby-rgss/mrblib/lib.rb).
enum Key {
  KEY_UP = 0,
  KEY_DOWN = 1,
  KEY_LEFT = 2,
  KEY_RIGHT = 3,
  KEY_A = 4,
  KEY_B = 5,
  KEY_C = 6,
};

// Terminals do not report key-release events, so a key is considered held for
// this long after the last byte that produced it was received.  Keeping this
// short makes menus responsive; the terminal's own auto-repeat sustains held
// movement keys.
constexpr uint32_t HOLD_MS = 150;

// ---------------------------------------------------------------------------
// Global backend state
// ---------------------------------------------------------------------------
bool g_active = false;
bool g_have_tty = false;
int g_scale = 1;
terminal_encode_fn g_encode = nullptr;
termios g_orig_termios;
bool g_termios_saved = false;

// Full-screen render buffer handed to LVGL (RENDER_MODE_FULL, RGB565).
std::vector<uint8_t> g_fb;

// Emit-rate statistics: how many bytes the active encoder pushes to the
// terminal, plus the fps-cap frame drops reported through profiler.hxx
// (profiler_total_frame_drops(), which is tracked unconditionally, not just
// under --profile). Recomputed about once a second and drawn on-screen just
// under the control legend.  On by default; toggled with --term_stats.
bool g_stats = true;
uint64_t g_stats_bytes = 0;   // bytes written to the terminal this interval
uint32_t g_stats_frames = 0;  // frames emitted this interval
uint32_t g_stats_last_ms = 0;
uint32_t g_stats_drops_mark = 0;  // profiler_total_frame_drops() at last report
bool g_stats_started = false;
std::string
    g_stats_line;  // last formatted report, drawn by terminal_append_stats

// ---------------------------------------------------------------------------
// Log console: a fixed block of rows above the image mirroring ng-log output.
// ---------------------------------------------------------------------------
// One captured log message: its ng-log severity (0=INFO..3=FATAL, selects the
// row colour) and the sanitised single-line text.
struct ConsoleLine {
  int severity = 0;
  std::string text;
};

bool g_console = false;  // wired to --term_console
// Reserved message rows, wired to --term_console_lines.
int g_console_lines = 5;
// A few more than g_console_lines are retained so raising the row count (or a
// burst arriving between frames) still has scrollback to show.
constexpr size_t CONSOLE_HISTORY = 256;
std::mutex g_console_mutex;  // guards g_console_buf (sink vs. render thread)
std::deque<ConsoleLine> g_console_buf;

struct KeyState {
  bool pressed = false;
  uint32_t expiry = 0;
};
KeyState g_keys[16];

// ---------------------------------------------------------------------------
// Async stdout writer: a background thread drains queued frames so flush_cb
// (the LVGL display driver callback) returns without blocking on I/O.  The
// encoder builds its output string on the render thread, hands it to this
// queue, and flush_cb calls lv_display_flush_ready immediately.
// ---------------------------------------------------------------------------
// Encoder-stage accumulation: each terminal_write call appends to this buffer.
// Thread-safe because flush_cb is called once per LVGL frame and never
// reentrantly.
std::string g_encode_buf;  // only accessed while g_writer_mtx held

// Complete frames for the writer thread.
std::mutex g_writer_mtx;
std::condition_variable g_writer_cv;
std::deque<std::string> g_frame_queue;  // guarded by g_writer_mtx
std::atomic<bool> g_has_frame{false};   // true when a frame is enqueued
std::thread g_writer_thread;
std::atomic<bool> g_writer_running{false};

// Accumulate `n` bytes from `p` into g_encode_buf.  Called during encoding via
// terminal_write → g_enqueue.  All writes on the render thread; no contention.
void writer_enqueue(const char* p, size_t n) {
  if (!g_writer_running.load())
    return;
  std::lock_guard<std::mutex> lock(g_writer_mtx);
  g_encode_buf.append(p, n);
}

void flush_encoder_to_stdout();

// Drain accumulated chunks into `out`, clearing g_encode_buf and signaling the
// writer thread.  Returns false if no frame was enqueued (writer busy or
// nothing to enqueue).
bool drain_and_enqueue(std::string& out) {
  std::lock_guard<std::mutex> lock(g_writer_mtx);
  out += std::move(g_encode_buf);
  g_encode_buf.clear();

  // Write encoder output to stdout — sixel/iterm encoders build their complete
  // frame in memory via terminal_write calls, all accumulated in g_encode_buf
  // which drain_and_exchange moved here on line ~128. The background writer
  // thread processes g_frame_queue asynchronously which may be delayed by the
  // LVGL event loop, so we must write directly to stdout regardless of queue
  // status. Every frame must be written — dropping it without output is a bug.

  // Move out from local variable (holds actual encoder output). Write directly
  // to stdout first — g_encode_buf was already moved above so flush_encoder_to_
  // stdout would find nothing in there. The sixel/iterm encoders need their
  // data written now, not later via an async writer thread that may be delayed.
  if (!out.empty()) {
    for (size_t off = 0; off < out.size();) {
      const ssize_t w =
          ::write(STDOUT_FILENO, out.data() + off, out.size() - off);
      if (w <= 0) {
        if (w < 0 && errno == EINTR)
          continue;
        break;
      }
      off += static_cast<size_t>(w);
    }
  }

  if (!g_has_frame.exchange(true)) {
    g_frame_queue.push_back(std::move(out));
    g_writer_cv.notify_one();
    // Clear has_frame immediately so the next drain_and_exchange call isn't
    // dropped into the out.clear() path without outputting.
    g_has_frame.store(false);
    return true;
  }
  // Writer busy — drop remaining in out (already written above) to avoid
  // unbounded growth, but output was already done on lines 143-153.
  return false;
}

void writer_entry() {
  while (g_writer_running.load()) {
    // Wait for a frame or shutdown signal.
    std::unique_lock<std::mutex> lock(g_writer_mtx);
    g_writer_cv.wait(
        lock, [&] { return g_has_frame.load() || !g_writer_running.load(); });

    if (!g_has_frame.load())
      continue;  // shutdown signal without frame
    g_has_frame.store(false);

    // Guard against empty queue (race between notification and push).
    while (g_has_frame.load() && !g_frame_queue.empty()) {
      const std::string frame = std::move(g_frame_queue.front());
      g_frame_queue.pop_front();
      lock.unlock();

      // Write to stdout (non-blocking, with EINTR retry).
      const char* p = frame.data();
      size_t n = frame.size();
      while (n > 0) {
        const ssize_t w = ::write(STDOUT_FILENO, p, n);
        if (w <= 0) {
          if (w < 0 && errno == EINTR)
            continue;
          if (w <= 0)
            break;
          p += w;
          n -= static_cast<size_t>(w);
        }
      }
      lock.lock();
    }
  }
}

// ---------------------------------------------------------------------------
// Direct-to-stdout encoder flush: writes the accumulated encoder buffer to
// stdout.  Called after g_encode finishes building a complete sixel/OSC frame
// so it reaches the terminal before flush_cb returns (no I/O blocking).
// ---------------------------------------------------------------------------
void flush_encoder_to_stdout() {
  std::string buf;
  {
    std::lock_guard<std::mutex> lock(g_writer_mtx);
    if (g_encode_buf.empty())
      return;
    buf = std::move(g_encode_buf);  // release lock before I/O
  }

  for (size_t off = 0; off < buf.size();) {
    const ssize_t w =
        ::write(STDOUT_FILENO, buf.data() + off, buf.size() - off);
    if (w <= 0) {
      if (w < 0 && errno == EINTR)
        continue;
      break;
    }
    off += static_cast<size_t>(w);
  }
}

// ---------------------------------------------------------------------------
// Time sources (LVGL needs a tick/delay source without SDL)
// ---------------------------------------------------------------------------
uint32_t now_ms() {
  timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return static_cast<uint32_t>(ts.tv_sec * 1000ULL + ts.tv_nsec / 1000000ULL);
}

void delay_ms(uint32_t ms) {
  timespec ts;
  ts.tv_sec = ms / 1000;
  ts.tv_nsec = static_cast<long>(ms % 1000) * 1000000L;
  nanosleep(&ts, nullptr);
}

// ---------------------------------------------------------------------------
// Terminal handling
// ---------------------------------------------------------------------------
void show_cursor() {
  static const char seq[] = "\x1b[?25h";
  terminal_write(seq, sizeof(seq) - 1);
}

// True once the alternate screen buffer has been entered, so teardown only
// leaves it if init actually switched to it.
bool g_alt_screen = false;

void restore_terminal() {
  // Shut down the async writer so it stops interleaving writes with our
  // teardown.
  if (g_writer_running.exchange(false)) {
    g_writer_cv.notify_one();
    if (g_writer_thread.joinable())
      g_writer_thread.join();
  }

  // Undo the visual state first (while still in raw mode), then hand the
  // terminal back to the shell.  Leaving the alternate screen buffer restores
  // the exact pre-game screen contents and cursor position; the explicit
  // erase covers the few terminals that keep image output in a layer that
  // survives the screen switch.
  show_cursor();
  if (g_alt_screen) {
    static const char leave_alt[] = "\x1b[2J\x1b[?1049l";
    terminal_write(leave_alt, sizeof(leave_alt) - 1);
    g_alt_screen = false;
  }
  if (g_termios_saved) {
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &g_orig_termios);
    g_termios_saved = false;
  }
}

void signal_handler(int sig) {
  restore_terminal();
  // Re-raise with the default handler so the exit status reflects the signal.
  signal(sig, SIG_DFL);
  raise(sig);
}

void init_terminal() {
  g_have_tty = isatty(STDIN_FILENO);
  if (g_have_tty && tcgetattr(STDIN_FILENO, &g_orig_termios) == 0) {
    g_termios_saved = true;
    termios raw = g_orig_termios;
    // Raw-ish mode: no line buffering, no echo, no signal generation (so we
    // can read Ctrl-C ourselves), non-blocking reads.
    raw.c_lflag &= ~(ICANON | ECHO | ISIG);
    raw.c_iflag &= ~(IXON | ICRNL);
    raw.c_cc[VMIN] = 0;
    raw.c_cc[VTIME] = 0;
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw);
  }

  std::atexit(restore_terminal);
  for (int sig : {SIGINT, SIGTERM, SIGHUP, SIGQUIT})
    signal(sig, signal_handler);

  // Switch to the alternate screen buffer so the game does not scribble image
  // data over the user's shell history; leaving it on exit restores what was
  // there before.  Images painted here belong to the alt buffer and are
  // discarded on switch-back in the common terminals (xterm, foot, WezTerm,
  // mlterm, ...).
  static const char enter_alt[] = "\x1b[?1049h";
  terminal_write(enter_alt, sizeof(enter_alt) - 1);
  g_alt_screen = true;

  static const char hide_cursor[] = "\x1b[?25l";
  terminal_write(hide_cursor, sizeof(hide_cursor) - 1);

  // Start the background writer thread. Spin until it is ready so flush_cb
  // never races a not-yet-running queue consumer. Do NOT signal has_frame here:
  // there are no frames yet; just start the thread and let flush_cb signal when
  // real data arrives.
  g_writer_running.store(true);
  {
    std::unique_lock<std::mutex> lock(g_writer_mtx);
    g_has_frame.store(false);
    g_frame_queue.clear();
    g_writer_thread = std::thread(writer_entry);
  }
}

// Once per ~second, recompute the emit rate (bytes the encoder pushed to the
// terminal) into g_stats_line and reset the interval counters.  The line is
// drawn into each frame by terminal_append_stats, so it never lands in the
// stdout image stream or scrolls the alternate screen.
void maybe_report_stats(uint32_t now) {
  if (!g_stats)
    return;
  if (!g_stats_started) {  // anchor the first interval; don't report a partial
    g_stats_started = true;
    g_stats_last_ms = now;
    g_stats_drops_mark = profiler_total_frame_drops();
    return;
  }
  const uint32_t dt = now - g_stats_last_ms;
  if (dt < 1000)
    return;
  const double secs = dt / 1000.0;
  const double mbps = static_cast<double>(g_stats_bytes) / secs / (1024 * 1024);
  const double fps = g_stats_frames / secs;
  const double kb_per_frame =
      g_stats_frames
          ? static_cast<double>(g_stats_bytes) / g_stats_frames / 1024.0
          : 0.0;
  const uint32_t total_drops = profiler_total_frame_drops();
  const uint32_t drops = total_drops - g_stats_drops_mark;
  char buf[160];
  std::snprintf(buf, sizeof(buf),
                "term_stats: %.1f KB/frame  %.2f MB/s  %.1f fps  drops=%u",
                kb_per_frame, mbps, fps, drops);
  g_stats_line.assign(buf);
  g_stats_bytes = 0;
  g_stats_frames = 0;
  g_stats_last_ms = now;
  g_stats_drops_mark = total_drops;
}

// Current terminal width in columns, so console rows can be truncated to avoid
// line-wrap (which would push the game image down a row).  Falls back to 80
// when the size is unknown (e.g. output is not a tty).
int term_cols() {
  winsize ws{};
  if (ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0 && ws.ws_col > 0)
    return ws.ws_col;
  return 80;
}

// Append `msg` (length `n`) to `out` as a single printable line: control bytes
// (newlines, tabs, ...) become spaces so one log entry never spans rows.
void append_sanitised(std::string& out, const char* msg, size_t n) {
  if (!msg)
    return;
  out.reserve(out.size() + n);
  for (size_t i = 0; i < n; ++i) {
    const unsigned char c = static_cast<unsigned char>(msg[i]);
    out += (c < 0x20 || c == 0x7f) ? ' ' : static_cast<char>(c);
  }
}

// SGR foreground colour for a log row, keyed by ng-log severity.  INFO is dim
// so it recedes; warnings/errors escalate to yellow/red so they stand out.
const char* severity_color(int severity) {
  switch (severity) {
    case 1:
      return "\x1b[33m";  // WARNING -> yellow
    case 2:
      return "\x1b[31m";  // ERROR -> red
    case 3:
      return "\x1b[1;31m";  // FATAL -> bold red
    default:
      return "\x1b[2m";  // INFO -> dim
  }
}

void flush_cb(lv_display_t* disp, const lv_area_t* area, uint8_t* px_map) {
  if (lv_display_flush_is_last(disp) && g_encode) {
    const int w = lv_area_get_width(area);
    const int h = lv_area_get_height(area);
    g_encode(w, h, g_scale, reinterpret_cast<const uint16_t*>(px_map));
    ++g_stats_frames;
    maybe_report_stats(now_ms());

    // Hand the accumulated frame to the writer thread so flush_cb returns
    // without blocking on I/O.  If the writer is still busy with a previous
    // frame, discard this one (the encoder already ran and updated g_fb).
    std::string frame;
    drain_and_enqueue(frame);
  }
  lv_display_flush_ready(disp);
}

// ---------------------------------------------------------------------------
// Keyboard input
// ---------------------------------------------------------------------------
void send_key(mrb_state* M, int key, bool press) {
  RClass* rgss = mrb_module_get(M, "RGSS");
  if (!rgss)
    return;
  RClass* input = mrb_module_get_under(M, rgss, "Input");
  if (!input)
    return;
  mrb_funcall(M, mrb_obj_value(input), press ? "press" : "release", 1,
              mrb_fixnum_value(key));
}

void hold_key(mrb_state* M, int key, uint32_t now) {
  if (key < 0)
    return;
  if (!g_keys[key].pressed) {
    g_keys[key].pressed = true;
    send_key(M, key, true);
  }
  g_keys[key].expiry = now + HOLD_MS;
}

}  // namespace

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------
void terminal_set_stats(bool enabled) {
  g_stats = enabled;
}

void terminal_append_legend(std::string& s) {
  // Reserve the top text row for a one-line key reference, then start the image
  // one row lower.  Terminals place the frame at the current cursor position,
  // so drawing the legend first (and emitting CR/LF) pins it above the picture
  // where it can never be overdrawn -- unlike positioning it after the image,
  // whose end-cursor location is not portable and left the legend overlapping
  // the bottom of the frame.  \x1b[K clears any stale text from the previous
  // frame; reverse video (SGR 7) renders the row as a status bar that stays
  // legible on any terminal background -- a dim foreground (SGR 2) was too
  // faint to read on light themes.
  s += "\x1b[K\x1b[7m";
  s += "Move: Arrows/WASD  OK: Z/Enter/Space  Cancel: X/Esc  A: C  Quit: Q";
  s += "\x1b[0m\r\n";
}

void terminal_append_stats(std::string& s) {
  // Draw the emit-rate report on its own row just under the legend, using the
  // same cursor-home overdraw model so it refreshes in place instead of
  // scrolling the alternate screen (the reason the old stderr print was
  // dropped).  No-op when stats are disabled so the row is not reserved.  The
  // row is always emitted once stats are on -- with a placeholder for the first
  // second before a rate has been measured -- so the image never shifts down a
  // row when the first sample arrives.  Reverse video (SGR 7) matches the
  // legend so both stay legible on any terminal background.
  if (!g_stats)
    return;
  s += "\x1b[K\x1b[7m";
  s += g_stats_line.empty() ? "term_stats: measuring..." : g_stats_line;
  s += "\x1b[0m\r\n";
}

void terminal_set_console(bool enabled, int lines) {
  g_console = enabled;
  g_console_lines = lines < 1 ? 1 : lines;
}

void terminal_console_push(int severity,
                           const char* file,
                           int line,
                           const char* msg,
                           size_t msg_len) {
  ConsoleLine entry;
  entry.severity = severity;
  // Prefix with the source location (as ng-log's own format does) so the
  // console is useful for tracing where a message came from.
  if (file && *file) {
    entry.text += file;
    entry.text += ':';
    entry.text += std::to_string(line);
    entry.text += "] ";
  }
  append_sanitised(entry.text, msg, msg_len);

  std::lock_guard<std::mutex> lock(g_console_mutex);
  g_console_buf.push_back(std::move(entry));
  while (g_console_buf.size() > CONSOLE_HISTORY)
    g_console_buf.pop_front();
}

void terminal_append_console(std::string& s) {
  // Reserve a fixed block (header + g_console_lines rows) regardless of how
  // many messages exist, so the image never shifts as logs arrive: empty slots
  // are drawn as blank cleared rows.  The newest messages sit at the bottom of
  // the block, right above the image, tailing like a real console.  Same
  // cursor-home overdraw + reverse-video header style as the legend/stats rows.
  if (!g_console)
    return;

  const int cols = term_cols();

  s += "\x1b[K\x1b[7m";
  s += "ng-log console";
  s += "\x1b[0m\r\n";

  std::lock_guard<std::mutex> lock(g_console_mutex);
  const int have = static_cast<int>(g_console_buf.size());
  const int shown = have < g_console_lines ? have : g_console_lines;
  const int blank = g_console_lines - shown;
  const int first = have - shown;  // index of the oldest shown message

  for (int row = 0; row < g_console_lines; ++row) {
    s += "\x1b[K";  // clear the whole row first (cursor is at column 0)
    if (row < blank) {
      s += "\r\n";  // no message yet for this slot
      continue;
    }
    const ConsoleLine& entry = g_console_buf[first + (row - blank)];
    s += severity_color(entry.severity);
    // Truncate to the terminal width so a long line cannot wrap and push the
    // image down.  Colour escapes have zero display width, so only the visible
    // text is measured.
    if (cols > 0 && static_cast<int>(entry.text.size()) > cols)
      s.append(entry.text, 0, static_cast<size_t>(cols));
    else
      s += entry.text;
    s += "\x1b[0m\r\n";
  }
}

// Callback wired during init: routes encoder output to the async writer instead
// of direct ::write calls.
using enqueue_fn = void (*)(const char* p, size_t n);
enqueue_fn g_enqueue = nullptr;

void terminal_write(const char* p, size_t n) {
  if (g_stats)
    g_stats_bytes += n;
  if (g_enqueue) {
    g_enqueue(p, n);
    return;
  }
  while (n > 0) {
    const ssize_t w = ::write(STDOUT_FILENO, p, n);
    if (w <= 0) {
      if (w < 0 && errno == EINTR)
        continue;
      break;
    }
    p += w;
    n -= static_cast<size_t>(w);
  }
}

// Exported so the mruby-rgss gem (Graphics.update) can drive input polling
// without a compile-time dependency on this translation unit.
extern "C" void rgss_terminal_poll(mrb_state* M) {
  terminal_poll(M);
}

void terminal_poll(mrb_state* M) {
  if (!g_active || !g_have_tty)
    return;

  const uint32_t now = now_ms();

  std::vector<char> buf;
  char chunk[64];
  for (;;) {
    const ssize_t n = ::read(STDIN_FILENO, chunk, sizeof(chunk));
    if (n <= 0)
      break;
    buf.insert(buf.end(), chunk, chunk + n);
    if (static_cast<size_t>(n) < sizeof(chunk))
      break;
  }

  for (size_t i = 0; i < buf.size();) {
    const unsigned char c = static_cast<unsigned char>(buf[i]);
    if (c == 0x1b && i + 2 < buf.size() && buf[i + 1] == '[') {
      switch (buf[i + 2]) {
        case 'A':
          hold_key(M, KEY_UP, now);
          break;
        case 'B':
          hold_key(M, KEY_DOWN, now);
          break;
        case 'C':
          hold_key(M, KEY_RIGHT, now);
          break;
        case 'D':
          hold_key(M, KEY_LEFT, now);
          break;
        default:
          break;
      }
      i += 3;
      continue;
    }

    switch (c) {
      case 'w':
      case 'W':
        hold_key(M, KEY_UP, now);
        break;
      case 's':
      case 'S':
        hold_key(M, KEY_DOWN, now);
        break;
      case 'a':
      case 'A':
        hold_key(M, KEY_LEFT, now);
        break;
      case 'd':
      case 'D':
        hold_key(M, KEY_RIGHT, now);
        break;
      case 'z':
      case 'Z':
      case '\r':
      case '\n':
      case ' ':
        hold_key(M, KEY_C, now);
        break;
      case 'x':
      case 'X':
      case 0x1b:  // 'x' or bare ESC = cancel
        hold_key(M, KEY_B, now);
        break;
      case 'c':
      case 'C':
        hold_key(M, KEY_A, now);
        break;
      case 'q':
      case 0x03:  // 'q' or Ctrl-C = quit
        restore_terminal();
        std::exit(0);
        break;
      default:
        break;
    }
    ++i;
  }

  // Auto-release keys whose hold window has elapsed.
  for (int k = 0; k < static_cast<int>(sizeof(g_keys) / sizeof(g_keys[0]));
       ++k) {
    if (g_keys[k].pressed &&
        static_cast<int32_t>(now - g_keys[k].expiry) >= 0) {
      g_keys[k].pressed = false;
      send_key(M, k, false);
    }
  }
}

lv_display_t* terminal_display_create(int32_t hor_res,
                                      int32_t ver_res,
                                      int scale,
                                      terminal_encode_fn encode) {
  g_scale = scale < 1 ? 1 : scale;
  g_encode = encode;

  lv_tick_set_cb(now_ms);
  lv_delay_set_cb(delay_ms);

  lv_display_t* disp = lv_display_create(hor_res, ver_res);
  if (!disp)
    return nullptr;

  lv_display_set_color_format(disp, LV_COLOR_FORMAT_RGB565);
  const uint32_t buf_size =
      static_cast<uint32_t>(hor_res) * ver_res * sizeof(uint16_t);
  g_fb.assign(buf_size, 0);
  lv_display_set_buffers(disp, g_fb.data(), nullptr, buf_size,
                         LV_DISPLAY_RENDER_MODE_FULL);
  lv_display_set_flush_cb(disp, flush_cb);

  init_terminal();
  // Wire the encoder output through our async writer.
  g_enqueue = writer_enqueue;
  g_active = true;
  return disp;
}
