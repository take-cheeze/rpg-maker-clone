- The bc2cpp review gates no longer judge reviewed sites: the NOMETHOD, PROVEN_MISS and TC1017 constant gates
  and the STRICT_HINT listing are kept as diagnostics only, and the `*_REVIEWED` lists, their update scripts and the
  source-annotation check are removed (ADR 0522). Unreviewed dead fallbacks, proven-class misses and untyped
  constants now pass the build.
