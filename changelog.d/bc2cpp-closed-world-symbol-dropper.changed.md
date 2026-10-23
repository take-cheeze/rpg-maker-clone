- The closed world's bc2cpp build drops more by-name method registrations.
  `tools/bc2cpp/static_dispatch_registrations.rb --closed-only` treats the
  closed binary as the whole program: Ruby test files, `scripts/` and `tools/`
  add no lookups to it, so their identifiers no longer block a name. The
  result is `tools/bc2cpp/static_dispatch_unregistered_closed.rb`, read only by
  the closed build (`static_dispatch_unregistered_for`). Every other target
  keeps `static_dispatch_unregistered.rb`. Native test sources stay in the
  scan, because they are compiled into the closed library.
