# Eligibility-probe text cleanup

Embedding safety asks whether a method compiles without `#error`; its generated
text is discarded. When an eligibility probe has no runtime-installed names
and no instruction text contains `#error`, it skips element-read GC-root
liveness analysis. That pass only appends roots and cannot change the answer.
Final emission retains root analysis. Error-bearing bodies keep the regular
root pass, and runtime-installed names retain their emitted-text audit.

Eligibility probes also skip final unused-register and dead-statement cleanup
when no runtime-installed names need auditing. Cleanup removes declarations,
labels and self-copies; it cannot remove or introduce an error directive.
Entry-specialization probes keep full optimization because their generated
clones are cached for final emission. The existing scoped `@clean_probe` flag
already excludes those probes and restores the caller's state on exceptions.

`BC2CPP_PROBE_TEXT_CLEANUP=0` restores these passes inside eligibility probes.
`BC2CPP_PROBE_REGISTER_FLOW=0` restores the original complete text-processing
path. Final C++ emission is unchanged under either control.

`scripts/bc2cpp/embed_family_check.rb` compares generated C++ and diagnostics
against the full-cleanup control, with an element read in an initializer, and
compares interpreted/compiled behavior including GC, reflection, inheritance
and Fiber use.

A Ruby 4.0.5/YJIT whole-engine run, with pinned submodule sources and warm scan
caches, measured two alternating control/candidate pairs:

| Pair | Control seconds | Candidate seconds | Control objects | Candidate objects |
| --- | ---: | ---: | ---: | ---: |
| A | 54.27 | 52.81 | 66,350,339 | 64,034,265 |
| B | 56.12 | 55.14 | 66,347,723 | 64,035,829 |

This saves about 2.31 million allocations (3.5%) and 1.7–2.7% elapsed time in
these runs. Generated C++ and diagnostics (excluding timing lines) were
byte-identical. GC time and peak memory varied between pairs; this does not
establish a retained-memory reduction. The workload generates all configured
engine/core owners in one closed-world call; it measures the compiler rather
than generated-game runtime or the complete C++ build.
