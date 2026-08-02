# 5. On-screen log console for the terminal backends

Date: 2026-07-24

## Status

Accepted

Extends [1. Terminal gaming with the sixel graphics protocol](0001-terminal-gaming-sixel.md)
and [3. Terminal gaming with the iTerm2 inline-image protocol](0003-terminal-gaming-iterm2.md).

## Context

The `--sixel` and `--iterm` backends (ADRs 0001 and 0003) paint every frame onto
the terminal's **alternate screen** with cursor-home overdraw. The engine also
logs through `ng-log`, which by default writes `ERROR` and above to **stderr**.
On a normal SDL run those two never collide, but under a terminal backend
stderr and the game image share the same screen: any `LOG(ERROR)` lands as stray
text somewhere over the picture, corrupting the frame until the next overdraw
(and, mid-frame, can split an image escape sequence).

ADR 0001 already hit this with the emit-rate stats and solved it by drawing them
*into the frame* as a reserved row rather than printing to stderr. Log messages
have the same problem but are more valuable to see: when something goes wrong in
a headless / SSH session there is no window and no visible stderr, so a failing
game just misbehaves silently.

We wanted the messages surfaced **in the terminal UI**, next to the game, in
both backends, without:

- coupling the `mruby-rgss` gem to `ng-log` (the gem links into mruby's own
  `mrbtest`, which must not drag in the logging library), or
- letting a long or multi-line message wrap and shove the image around.

## Decision

Add a **log console**: a fixed block of rows drawn above the game image,
alongside the existing control legend and stats rows, that tails recent
`ng-log` messages. Selected with `--term_console` (on by default,
`--noterm_console` to disable) and sized with `--term_console_lines=N`
(default 5).

The work is split across the two existing seams so the gem stays `ng-log`-free:

- **Executable side** (`src/log_console.cxx`): an `nglog::LogSink` subclass whose
  `send()` forwards each message — severity, source file/line, text — into the
  terminal backend through the exported `terminal_console_push`. `main.cxx`
  installs it (`log_console_install`) only when a terminal backend is active and
  the console is enabled.
- **Gem side** (`mruby-rgss/src/terminal.cxx`): a mutex-guarded ring buffer of
  the last messages, plus `terminal_append_console`, which the sixel and iTerm2
  encoders call right after `terminal_append_stats`. It emits a reverse-video
  header row and exactly `--term_console_lines` message rows, tailing the buffer
  newest-at-the-bottom (nearest the image). The buffer stores only ints and
  strings, so the gem never sees an `ng-log` type.

Details that make it robust:

- **Fixed height.** The block is always `header + N` rows regardless of how many
  messages exist (empty slots are blank cleared rows), so the image never shifts
  as logs arrive — the same reasoning that pins the legend above the frame in
  ADR 0001.
- **No wrap.** Each row is truncated to the terminal width (`TIOCGWINSZ`) so a
  long line cannot wrap onto a second row and push the image down.
- **Single line per message.** Control bytes (newlines, tabs) are replaced with
  spaces on capture, so one log entry occupies exactly one row.
- **Severity colour.** Rows are coloured by `ng-log` severity — dim `INFO`,
  yellow `WARNING`, red `ERROR`, bold-red `FATAL` — so problems stand out.
- **Thread-safe.** `ng-log` may call the sink from whichever thread ran the
  `LOG()` line; the push path only locks the ring-buffer mutex and never logs,
  matching `LogSink`'s contract.

Because the console now carries the messages, `main.cxx` also calls
`nglog::SetStderrLogging(NGLOG_FATAL)` when a terminal backend is active, so
`ng-log` stops writing to stderr (and thus stops scribbling on the image).
`FATAL` still prints, but it aborts and restores the terminal on the way out, so
there is no surviving frame to corrupt. File logging is untouched.

## Consequences

- Engine log output is visible on-screen in both terminal backends, including on
  headless / SSH hosts where there is no window — advancing the "run anywhere"
  goal from ADR 0001.
- stderr no longer corrupts the terminal image while a backend is active (a
  pre-existing latent bug, not just a console feature).
- The `mruby-rgss` gem keeps no compile-time dependency on `ng-log`; the sink
  lives in the executable, mirroring the `rgss_terminal_poll` / `rgss_set_display`
  seams. The console renderer and buffer live in the shared `terminal.cxx`, so
  the sixel and iTerm2 paths stay identical (each just adds one
  `terminal_append_console` call).
- Trade-offs / follow-up work:
  - The console occupies rows *above* the image because a terminal backend
    cannot portably know the cursor position *after* an inline image (the same
    limitation that put the legend on top in ADR 0001); a genuinely bottom-docked
    panel would need per-terminal cell-size probing.
  - Only the plain message text is shown (no timestamp column) to keep rows
    short; the full record is still in the log file.
  - There is no runtime show/hide key: a fixed-height block keeps the image
    position stable and avoids the stale-row / screen-clear handling a toggle
    would require. It can be sized or disabled from the command line instead.
