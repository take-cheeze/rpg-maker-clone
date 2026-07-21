#include "sixel.hxx"

#include <cerrno>
#include <csignal>
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
termios g_orig_termios;
bool g_termios_saved = false;

// Full-screen render buffer handed to LVGL (RENDER_MODE_FULL, RGB565).
std::vector<uint8_t> g_fb;

// Reused across frames to avoid per-frame allocation churn.
std::string g_out;
std::vector<uint8_t> g_oidx;
std::string g_line;

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
void write_all(const char* p, size_t n) {
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

void show_cursor() {
  static const char seq[] = "\x1b[?25h";
  write_all(seq, sizeof(seq) - 1);
}

void restore_terminal() {
  if (g_termios_saved) {
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &g_orig_termios);
    g_termios_saved = false;
  }
  show_cursor();
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

  static const char hide_cursor[] = "\x1b[?25l";
  write_all(hide_cursor, sizeof(hide_cursor) - 1);
}

// ---------------------------------------------------------------------------
// Sixel encoding
// ---------------------------------------------------------------------------
// Fixed 6x6x6 colour cube (216 registers).  Direct quantisation keeps encoding
// O(pixels) with no palette search, which is important for interactive frame
// rates.
inline int quant6(int v) {
  const int q = (v * 6) / 256;
  return q > 5 ? 5 : q;
}

const std::string& palette_definition() {
  static const std::string def = [] {
    std::string s;
    for (int i = 0; i < 216; ++i) {
      const int r = ((i / 36) % 6) * 255 / 5;
      const int g = ((i / 6) % 6) * 255 / 5;
      const int b = (i % 6) * 255 / 5;
      s += '#';
      s += std::to_string(i);
      s += ";2;";
      s += std::to_string(r * 100 / 255);
      s += ';';
      s += std::to_string(g * 100 / 255);
      s += ';';
      s += std::to_string(b * 100 / 255);
    }
    return s;
  }();
  return def;
}

// Run-length-encode a line of sixel bytes onto `s`, trimming trailing empties.
void emit_rle(std::string& s, const std::string& line) {
  size_t n = line.size();
  while (n > 0 && line[n - 1] == '?')  // trailing background needs no output
    --n;
  size_t i = 0;
  while (i < n) {
    const char c = line[i];
    size_t j = i + 1;
    while (j < n && line[j] == c)
      ++j;
    const size_t run = j - i;
    if (run >= 4) {
      s += '!';
      s += std::to_string(run);
      s += c;
    } else {
      s.append(run, c);
    }
    i = j;
  }
}

void encode_frame(int w, int h, const uint16_t* pix) {
  const int scale = g_scale;
  const int out_w = w * scale;
  const int out_h = h * scale;

  // Quantise (and upscale) the whole frame once into a palette-index buffer.
  g_oidx.resize(static_cast<size_t>(out_w) * out_h);
  for (int oy = 0; oy < out_h; ++oy) {
    const uint16_t* row = pix + (oy / scale) * w;
    uint8_t* dst = g_oidx.data() + static_cast<size_t>(oy) * out_w;
    for (int ox = 0; ox < out_w; ++ox) {
      const uint16_t p = row[ox / scale];
      // RGB565 -> 8 bit per channel.
      const int r = ((p >> 11) & 0x1f) << 3;
      const int g = ((p >> 5) & 0x3f) << 2;
      const int b = (p & 0x1f) << 3;
      dst[ox] =
          static_cast<uint8_t>(quant6(r) * 36 + quant6(g) * 6 + quant6(b));
    }
  }

  std::string& s = g_out;
  s.clear();
  s += "\x1b[H";  // cursor home: overdraw the previous frame in place
  s += "\x1bPq";  // enter sixel mode
  s += "\"1;1;";  // raster attributes: 1:1 aspect ratio
  s += std::to_string(out_w);
  s += ';';
  s += std::to_string(out_h);
  s += palette_definition();

  bool used[216];
  int used_list[216];
  for (int by = 0; by < out_h; by += 6) {
    const int bh = (out_h - by < 6) ? (out_h - by) : 6;

    // Collect the colours present in this 6-row band.
    std::memset(used, 0, sizeof(used));
    int used_count = 0;
    for (int r = 0; r < bh; ++r) {
      const uint8_t* rowp = g_oidx.data() + static_cast<size_t>(by + r) * out_w;
      for (int ox = 0; ox < out_w; ++ox) {
        const uint8_t c = rowp[ox];
        if (!used[c]) {
          used[c] = true;
          used_list[used_count++] = c;
        }
      }
    }

    for (int u = 0; u < used_count; ++u) {
      const int c = used_list[u];
      s += '#';
      s += std::to_string(c);
      g_line.assign(out_w, 0);  // raw 6-bit accumulators (one bit per row)
      for (int r = 0; r < bh; ++r) {
        const uint8_t* rowp =
            g_oidx.data() + static_cast<size_t>(by + r) * out_w;
        const char bit = static_cast<char>(1 << r);
        for (int ox = 0; ox < out_w; ++ox)
          if (rowp[ox] == c)
            g_line[ox] = static_cast<char>(g_line[ox] | bit);
      }
      // A sixel data byte is 0x3F ('?') plus the 6-bit column value.
      for (char& ch : g_line)
        ch = static_cast<char>('?' + ch);
      emit_rle(s, g_line);
      s += (u + 1 < used_count) ? '$' : '-';  // overlay next colour / new band
    }
    if (used_count == 0)
      s += '-';
  }

  s += "\x1b\\";  // exit sixel mode
  write_all(s.data(), s.size());
}

void flush_cb(lv_display_t* disp, const lv_area_t* area, uint8_t* px_map) {
  if (lv_display_flush_is_last(disp)) {
    const int w = lv_area_get_width(area);
    const int h = lv_area_get_height(area);
    encode_frame(w, h, reinterpret_cast<const uint16_t*>(px_map));
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

// Exported so the mruby-rgss gem (Graphics.update) can drive input polling
// without a compile-time dependency on this translation unit.
extern "C" void rgss_terminal_poll(mrb_state* M) {
  sixel_terminal_poll(M);
}

void sixel_terminal_poll(mrb_state* M) {
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

lv_display_t* sixel_display_create(int32_t hor_res,
                                   int32_t ver_res,
                                   int scale) {
  g_scale = scale < 1 ? 1 : scale;

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
