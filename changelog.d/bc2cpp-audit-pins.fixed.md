- **bc2cpp**: re-pinned the native audits that recent `lib.cxx` and mruby edits
  had silently invalidated (native ivar scopes, the `to_s`/`split`/`bytes`
  result facts), restoring their typed slots, and added
  `scripts/bc2cpp/audit_pins_check.rb` so a stale pin fails CI instead of
  quietly withdrawing facts.
