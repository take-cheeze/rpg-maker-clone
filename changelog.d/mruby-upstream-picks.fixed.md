- **mruby** carries 152 upstream bug fixes picked onto the fork (crashes,
  out-of-bounds reads, GC-unsafe paths, wrong numeric, String, Hash, IO and
  sprintf results) and no longer sends `==`, `hash`, `initialize_copy` or
  `const_added` by name when the builtin would run; bc2cpp's native audits pin
  the changed sources and its frame runtime and numeric helpers follow.
