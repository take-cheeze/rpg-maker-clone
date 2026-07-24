#pragma once

#include <cstddef>
#include <cstdint>
#include <string>

// Forward declarations to avoid pulling heavy headers into every includer.
struct mrb_state;
struct _lv_display_t;
typedef struct _lv_display_t lv_display_t;

// Append the one-line control legend (dim, cleared to end of line, terminated
// with CR/LF) that every terminal backend draws on the top row, just above the
// game image.  Encoders call this right after homing the cursor so the legend
// is pinned above the picture and can never be overdrawn.  Shared so the sixel
// and iTerm2 backends stay identical.
void terminal_append_legend(std::string& s);

// Append the emit-rate report row (frame size, MB/s, fps) drawn just under the
// legend, in the same dim/cleared/CR-LF style.  Encoders call this right after
// terminal_append_legend.  The text is refreshed about once a second; a no-op
// when --term_stats is disabled.
void terminal_append_stats(std::string& s);

// A per-protocol frame encoder.  It is handed one finished frame as an RGB565
// buffer at the logical game resolution (`w`x`h`) plus the integer upscale
// factor `scale`, and is responsible for turning it into a terminal byte stream
// and emitting it with `terminal_write`.  The sixel and iTerm2 backends differ
// only in this function; everything else (raw mode, input, timing, the LVGL
// display/buffer wiring) is shared.
using terminal_encode_fn = void (*)(int w,
                                    int h,
                                    int scale,
                                    const uint16_t* pix);

// Create a windowless LVGL display that renders each frame to the controlling
// terminal via `encode`, instead of opening a desktop window.
//
// `hor_res`/`ver_res` are the logical game resolution; `scale` upscales the
// emitted image by an integer nearest-neighbour factor so pixel-art is legible
// in a terminal.  The created display is registered as LVGL's default display.
//
// As a side effect the controlling terminal is switched into raw mode (so
// keyboard input can be read without line buffering) and into the alternate
// screen buffer (so the game does not overwrite the user's shell history), and
// a monotonic tick/delay source is installed so LVGL runs without SDL.  The
// terminal state is restored automatically on process exit and on fatal
// signals.
lv_display_t* terminal_display_create(int32_t hor_res,
                                      int32_t ver_res,
                                      int scale,
                                      terminal_encode_fn encode);

// Poll the terminal for keyboard input and forward it to the RGSS::Input
// module.  Safe to call unconditionally: it is a no-op until a terminal display
// has been created.  Meant to be invoked once per frame from Graphics.update.
void terminal_poll(mrb_state* M);

// Write raw bytes to the controlling terminal, handling partial writes and
// EINTR.  Meant for encoders assembling a frame.
void terminal_write(const char* p, size_t n);

// Enable or disable the periodic emit-rate report (frame size, MB/s, fps)
// printed to stderr about once a second while a terminal backend is active.
// Enabled by default; wired to the --term_stats flag.  Has no effect unless a
// terminal display was created (the SDL path never calls the encoder).
void terminal_set_stats(bool enabled);

// ---------------------------------------------------------------------------
// Log console
// ---------------------------------------------------------------------------
// A TUI log panel that mirrors ng-log output on-screen, drawn above the game
// image just like the legend and stats rows.  Because a terminal backend paints
// each frame onto the alternate screen with cursor-home overdraw, anything
// ng-log wrote to stderr would scribble over the picture; the console reserves
// a fixed block of rows for the last few messages instead, tailing them like a
// real console (newest at the bottom, nearest the image).
//
// The pieces are split across the executable and this gem so the gem keeps no
// compile-time dependency on ng-log: the executable installs an nglog::LogSink
// (see src/log_console.cxx) that forwards each message here through
// terminal_console_push, and the encoders draw the buffered lines with
// terminal_append_console.

// Enable the log console and set how many message rows it reserves (a header
// row is always drawn above them).  `lines` is clamped to at least 1.  Wired to
// the --term_console / --term_console_lines flags; a no-op visually until an
// encoder calls terminal_append_console.
void terminal_set_console(bool enabled, int lines);

// Append one log line to the console's ring buffer.  Thread-safe: ng-log may
// call the installed sink from whichever thread ran the LOG() statement.
// `severity` uses ng-log's LogSeverity ordering (0=INFO, 1=WARNING, 2=ERROR,
// 3=FATAL) and selects the row colour; `file`/`line` are the message's source
// location (may be null/0).  The message is stored sanitised to a single
// printable line.  Safe to call before a terminal display exists.
void terminal_console_push(int severity,
                           const char* file,
                           int line,
                           const char* msg,
                           size_t msg_len);

// Append the log-console block (header row plus the reserved message rows) to
// `s` in the same dim/cleared/CR-LF style as the legend and stats rows.
// Encoders call this right after terminal_append_stats.  A no-op when the
// console is disabled.  The block is a fixed height so the game image never
// shifts as messages arrive; missing rows are drawn blank.
void terminal_append_console(std::string& s);
