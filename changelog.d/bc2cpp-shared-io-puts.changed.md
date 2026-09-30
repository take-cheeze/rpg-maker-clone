- bc2cpp compiles every explicit-receiver `puts` to one shared helper instead of
  an inline guard plus a per-site by-name fallback (and a second copy for builds
  without mruby-io). Behaviour is unchanged: a redirected `$stdout`/`$stderr` or
  an `IO#puts` override still dispatches by name. See ADR 0284.
