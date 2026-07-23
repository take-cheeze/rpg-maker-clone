#include "terminal.hxx"

#include <cerrno>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <string>
#include <vector>

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
// terminal, printed to stderr about once a second.  On by default; toggled with
// --term_stats.
bool g_stats = true;
uint64_t g_stats_bytes = 0;   // bytes written to the terminal this interval
uint32_t g_stats_frames = 0;  // frames emitted this interval
uint32_t g_stats_last_ms = 0;
bool g_stats_started = false;

struct KeyState {
  bool pressed = false;
  uint32_t expiry = 0;
};
KeyState g_keys[16];

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
}

// Once per ~second, print the emit rate (bytes the encoder pushed to the
// terminal) to stderr and reset the interval counters.  stderr is used so the
// numbers do not land in the stdout image stream; redirect it (2>stats.log) to
// keep them off the game screen.
void maybe_report_stats(uint32_t now) {
  if (!g_stats)
    return;
  if (!g_stats_started) {  // anchor the first interval; don't report a partial
    g_stats_started = true;
    g_stats_last_ms = now;
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
  std::fprintf(stderr, "[term_stats] %.1f KB/frame  %.2f MB/s  %.1f fps\n",
               kb_per_frame, mbps, fps);
  g_stats_bytes = 0;
  g_stats_frames = 0;
  g_stats_last_ms = now;
}

void flush_cb(lv_display_t* disp, const lv_area_t* area, uint8_t* px_map) {
  if (lv_display_flush_is_last(disp) && g_encode) {
    const int w = lv_area_get_width(area);
    const int h = lv_area_get_height(area);
    g_encode(w, h, g_scale, reinterpret_cast<const uint16_t*>(px_map));
    ++g_stats_frames;
    maybe_report_stats(now_ms());
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
  // one row lower.  Terminals place the frame at the current cursor position, so
  // drawing the legend first (and emitting CR/LF) pins it above the picture
  // where it can never be overdrawn -- unlike positioning it after the image,
  // whose end-cursor location is not portable and left the legend overlapping
  // the bottom of the frame.  \x1b[K clears any stale text from the previous
  // frame and the dim SGR keeps the legend visually secondary to the game.
  s += "\x1b[K\x1b[2m";
  s += "Move: Arrows/WASD  OK: Z/Enter/Space  Cancel: X/Esc  A: C  Quit: Q";
  s += "\x1b[0m\r\n";
}

void terminal_write(const char* p, size_t n) {
  if (g_stats)
    g_stats_bytes += n;
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
  g_active = true;
  return disp;
}
