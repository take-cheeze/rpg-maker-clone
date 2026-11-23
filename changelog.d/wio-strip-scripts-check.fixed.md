- `scripts/wio/strip_scripts_check.rb` runs again: it loaded the removed
  unreachable-method pass, and its clock rewrite no longer matched the
  no-Float markers in `lsd_io.rb`. CI now runs it and the Wio dropped-gems
  check.
