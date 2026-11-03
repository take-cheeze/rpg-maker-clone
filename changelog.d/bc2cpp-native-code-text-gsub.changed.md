- bc2cpp strips comments and prose string literals from native C/C++ sources
  with a single `gsub` instead of a per-character walk, removing about 3 million
  temporary Strings (19.6% of allocations) from a sealed Optcarrot compilation
  whenever native file facts are recomputed.
