- bc2cpp's native brace-body scanner compares bytes instead of one-character
  Strings, removing about 751,000 allocations (4.9%) from a sealed Optcarrot
  compilation.
