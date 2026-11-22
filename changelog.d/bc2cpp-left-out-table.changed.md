- **bc2cpp:** the closed build's methods that are only called directly are
  now listed in one read-only table instead of one generated call each. The
  Wio Terminal image is about 78 KB smaller in flash, and the heap no longer
  holds an entry per left-out name for `respond_to?`.
