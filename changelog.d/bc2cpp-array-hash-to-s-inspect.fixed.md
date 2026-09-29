- bc2cpp now handles base String, Integer, Array, and Hash `to_s` with native
  fast paths when the relevant methods have no Ruby overrides. Arrays and Hashes
  use mruby's public `mrb_inspect` helper to preserve recursive inspect behavior.
