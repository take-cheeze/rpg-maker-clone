- **bc2cpp**: `scripts/bc2cpp/enumerator_args_check.rb` pins the closed world's
  writers of Enumerator's `@args` (three reviewed writers, each storing an
  Array) and rejects dynamic ivar writes. It is the premise for typing `@args`
  as an Array; the dispatch analysis does not use it yet.
