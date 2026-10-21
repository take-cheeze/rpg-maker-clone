# 0539. Analysis-only presym and Onigmo headers for the native return analysis

Date: 2026-10-21

## Status

Accepted

## Context

The native return analysis (ADR 0537) reads each closed-world native source with clang, and a source clang cannot
parse keeps only the regex return kinds. Three sources failed for reasons the closed build does not cover:

- The closed build's presym list (`closed/presym`) holds the symbols of the gems the closed build compiles. Sources the
  closed world still reads (`mruby-method`'s `method.c`, `mruby-onig-regexp`, `mruby-dir`) name symbols outside that
  list, such as `MRB_SYM___proc` and `MRB_IVSYM__source`, so they did not parse.
- `mruby-onig-regexp` includes `<oniguruma.h>`, which the closed build does not provide. The gem's rake file bundles
  `onigmo.h` only when it builds the gem.
- Those are the bodies of `Method#to_s`, `OnigMatchData#to_s` and `OnigRegexp#inspect`, so `to_s` and `inspect` were
  refused for want of a body, not for a disagreement.

The closed build's own headers cannot be changed to cover them: the closed library is compiled against them, and its
presym numbering must match its objects.

## Decision

`scripts/bc2cpp/analysis_headers.rb` writes `CLOSED_BUILD_DIR/analysis/include`, which holds:

1. `mruby/presym/id.h`: a presym ID header over the union of the closed build's presym list and every symbol the
   closed world's native sources name. The names come from mruby's own scanner (`lib/mruby/presym.rb`), run over each
   source preprocessed with `-DMRB_PRESYM_SCANNING`, and the header is written by mruby's own writer.
2. `onigmo.h`, extracted from the bundled tarball, and `oniguruma.h`, which includes it.

`BaseRbsAll.core_flags` and `flags_for` put this directory first on the include path when a closed build is given, so
the base generator and the return-kind table (`native_fn_kinds.rb`) see it. The closed compile does not: nothing in
the closed library includes `analysis/`, and the closed presym numbering is unchanged.

`closed_build.bash` runs the script after the build. The native source list is `BaseRbsAll.closed_native_sources`, the
list coverage_report.rb hands bc2cpp as NATIVE_SRCS, without `test/` directories.

## Consequences

- The analysis reads the closed world's sources as the build does, so `Method#to_s`, `OnigMatchData#to_s` and
  `Symbol#to_s` have bodies. Measured over the closed world's sources (patched mruby, as CI applies it), `to_s` is
  admitted as String, and `to_i` and `to_f` as Integer and Float.
- The overlay's presym numbers are not the build's. They are only read for names, and no analysis output carries them.
- The analysis depends on the same mruby patches as the build. A checkout without them fails to parse `symbol.c`
  (the closed table is the compact form), which is the state a local analysis without `standalone_prep.bash`'s patches
  is in. CI applies the patches first.
- `oniguruma.h` is a shim. The header the gem's own build finds is the bundled `onigmo.h`; the shim is for analysis only.
- Still unparsed in the closed world: `profiler.cxx` (`mrb_gc_type_counts` is not declared in the closed build).
  `io_hal.c` is wio-only and is outside the closed world.
