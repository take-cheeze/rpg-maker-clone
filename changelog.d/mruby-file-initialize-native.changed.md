mruby fork: native `File#initialize`, no VM entry

`File#initialize` (mruby-io `mrblib/file.rb`) was the last Ruby method of the
fork the core compile refused (`super(fd, mode)` with explicit arguments has no
by-name lookup in that job), so every `File.new` / `File.open` ran it as
bytecode. The fork now has `mrb_file_init` in `mruby-io/src/file.c`: it keeps
the path in `@path`, opens it with `IO.sysopen` for a path, and calls
`IO#initialize` (found from `File`'s superclass) with the block it was given.
The 3rd/mruby pin moves to `claude/file-initialize-cfunc`; the audited hashes of
`file.c` and `file.rb` follow.
