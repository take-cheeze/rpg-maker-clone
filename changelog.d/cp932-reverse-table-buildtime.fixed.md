- **Fixed a real, silent data-corruption bug in the CP932 encode/decode
  table**: `mruby-lcf/cp932_to_unicode.rb` wrote each entry's free-form
  comment straight into a `//` comment, and a comment ending in a literal
  backslash splices onto the next source line — silently deleting that
  line's own table entry (confirmed: 74 such lines in a real generated
  file). The array's declared length was never adjusted to match, so
  binary search has been reading past the true end of the compiled table
  for months. Comments are now sanitized to backslash-free printable ASCII.
- **`utf8_to_cp932` (mruby-lcf) no longer builds its own reverse-sorted
  copy of the whole CP932 table in a heap-allocated `std::vector` the first
  time any string is encoded** — a real ~38 KB RAM allocation invisible to
  every static flash/RAM measurement, on a board with none to spare. Both
  directions are now generated at build time and live in flash, verified
  byte-for-byte against the (corrected) old runtime construction and via a
  real round-trip through the actual compiled code. Costs +36,904 bytes of
  flash on a real relink — a fair trade for removing a real RAM/correctness
  risk. See ADR 111.
