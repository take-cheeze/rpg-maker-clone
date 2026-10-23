- **Wio build**: `scripts/wio/strip_inline_helpers.rb` expected the old
  five-line `return_from_call`, so the wio build stopped at the drift guard.
  Its expected length is now eight lines.
