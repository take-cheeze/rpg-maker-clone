- The terminal backends (`--iterm` / `--sixel`) now hand the shell back a
  visible cursor and the normal screen. Their teardown emits show-cursor
  (`ESC [ ? 25 h`) and leave-alternate-screen (`ESC [ ? 1049 l`) through
  `terminal_write`, which the async stdout writer had quietly swallowed since
  it landed: `restore_terminal` stops the writer thread *before* writing them,
  and `writer_enqueue` drops every byte once the writer is down (and, before
  that, only buffers into `g_encode_buf`, which nothing drains after the final
  frame). Only the `tcsetattr` raw-mode restore -- a direct syscall -- survived,
  so quitting a terminal-mode game left the prompt cursorless on top of the last
  game frame. Teardown now clears the writer hook and writes straight to stdout.
