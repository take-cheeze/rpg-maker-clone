- **bc2cpp: rescue handlers share their logging code.** The
  `$stderr.puts "[RPG2k] ...: #{e.message}"` line of a compiled `rescue`
  handler is one call of a helper that the handlers differing only in their
  text share; the log output is unchanged. About 6 KB less Wio flash.
  `BC2CPP_RESCUE_SHARED_HANDLER=0` turns it off.
