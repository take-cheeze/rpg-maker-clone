# 412. bc2cpp type check: a report-only, gradual view of the whole-program inference

Date: 2026-10-12

## Status

Accepted

## Context

bc2cpp already proves a lot about a program: argument classes at call sites (ADR 0295/0296), return classes
(ADR 0289), ivar classes (ClassLayout), element classes, record hashes (ADR 0285), and why an ivar stays untyped
(ADR 0382). The facts exist only as `== section ==` text on stderr and as generated C++. Nobody can ask "what is the
type of this parameter, why is that one unknown, which of my annotations is wrong, and which declaration would help
the most?" without reading a 12-minute coverage report.

Annotations (`# bc2cpp: (T) -> R`) are guarded hints (ADR 0210/0290/0380). A wrong one silently costs an
optimization, except for the narrow fixnum/symbol check of RBS_SEED_CONTRADICTION, which aborts a build.

## Decision

`scripts/bc2cpp/type_check.rb` runs the analysis a build runs (no C++ is compiled) and reports.

* `BC2CPP_TYPE_FACTS=<path>` (bc2cpp.rb, off in every build): after all analyses, `tools/bc2cpp/type_facts.rb` writes
  one JSON row per method (parameters with type, source and reason; return), ivar (type, element, source, ADR 0382
  bucket and the unresolved stores' file:line), constant, annotation and contradiction. It reads settled state and
  changes nothing: the generated C++ is byte-identical (checked). In this mode the contradiction check reports instead
  of aborting.
* Contradictions (TC1001) are the ones RBS_SEED_CONTRADICTION already finds (fixnum/symbol, class argument) plus a
  declared class return against a closed inferred class set; in this mode they are reported with the annotation's
  file:line instead of aborting. A declared superclass or an incomplete inferred set is an absent fact,
  not a contradiction (same rule as RBS_SEED_CONTRADICTION). Annotation tokens bc2cpp ignores and annotations with
  the wrong parameter count are warnings (TC1004): previously silent. **Amended by ADR 0426: now errors.**
* Reasons: parameters: `poly:N`, `dynamic-name`, `never-called`, `packed-caller`, or the receiver-proof `why`
  (`no_candidate:<rule>`, `dropped:<kinds>`); returns: the producers of the unresolved return sites
  (`send_result:<name>(native|ruby|mixed|unregistered)`, `ivar:@x`, `param`, ...); ivars: `any` / `opaque` plus the
  ADR 0382 bucket.
* Send ranking: the receiver-proof rows (ADR 0331, `BC2CPP_RECEIVER_PROOF_REPORT`) are grouped by the declaration a
  signature would attach to (parameter, ivar, callee return, constant). Without `--what-if` only the as-compiled
  by-name line counts are known (`BC2CPP_RECEIVER_PROOF_NO_WHATIF=1` skips the forced recompiles); with it each group
  also states how many lines go away at the floor (any class that answers). The `argument` row's detail is now
  `arg<k>` instead of `-`.
* Output: text with `file:line:col: severity: message [TCnnnn]` diagnostics (errors, then warnings, then info;
  exit 1 only for errors), `--format json`, `--format tsv`.

Honest limit: with guarded hints a correct signature adds a direct arm but keeps the by-name else arm, so the
by-name line count does not fall until hints are forced (strict tier). The ranking therefore says "would act on".

## Consequences

The inference becomes inspectable and reviewable; wrong annotations are found with a location. The cost is one more
env-gated block in bc2cpp.rb and a column change in an existing debug report. Signature files (RBS) and RBS output are
separate follow-ups on top of the same facts.
