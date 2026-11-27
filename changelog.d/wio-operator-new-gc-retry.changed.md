- **Wio (Renode game firmware): a failed `operator new` runs a full GC and
  retries once** before stopping the run, as mruby's own allocator already
  does. It is skipped while LVGL draws, before the RGSS gem is up, after
  `mrb_close` has started, and inside a GC. The log line
  `[Wio] operator new N bytes: full GC #K` reports each retry.
