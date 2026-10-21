# 0522. bc2cpp review gates read source annotations, not central lists

Date: 2026-10-20

## Status

Withdrawn. The source annotations, the annotation gates and the check scripts were removed again; the gates no longer judge reviews, so unreviewed dead fallbacks, proven misses and untyped constants pass the build.

## Context

Four bc2cpp gates judge a closed-world site by reading a human review of it:
NOMETHOD (ADR 0226, dead fallbacks), PROVEN_MISS (ADR 0275, proven-class misses), STRICT_HINT (ADR 0419, forced hints)
and CONSTANT (ADR 0491, untyped engine constants). Each kept its reviewed sites in a hand-maintained Ruby list keyed by
compiled `owner#method -> name`, with an update script that regenerated the list and a check script that proved it
exact in both directions.

The keys were coarser than the sites. A key named a method, so one review covered every send of that name in it, and
the list could only say which method held a site, not which line. The NOMETHOD list alone had 2,877 entries in a file
of about 3,000 lines. Every change that moved a send, or that changed which methods compile, could make entries stale
and regenerate a file that then had to be read again.

## Decision

A review is a comment in the source, next to the site it judges:

```ruby
# bc2cpp-reviewed: nomethod width -- dead fallback (ADR 0226)
@right_contents.draw_text NAME_COL_W, y, ...
```

- The comment sits on the site's line or on the line above it, or above the statement when the site is on a
  backslash-continued line. It names one or more keys separated by commas (`gate spec`), so one line can hold several
  reviewed sends.
- The keys are `nomethod <name>`, `proven_miss <kind> <Class>.<name>`, `strict_hint <family> <name>` and
  `constant <Name>`. The reason follows ` -- ` and is not compared.
- Compiled markers now carry the send's source site (`/* CLOSED_WORLD nomethod: recv.name @ file:line */`). The
  instruction compiler records the current instruction's source line (`CodeGen#insn_source_site`), so every codegen
  path that emits a marker names where its send is written. A marker with no source line (`?:0`) matches no
  annotation and fails its gate.
- The gates read the annotation through `tools/bc2cpp/source_review.rb`, which is also what DIRECT_RAISE uses to decide
  whether a reviewed fallback raises directly.
- A reviewed site is a source line, not a method, so an annotation is stale exactly when its line no longer holds a
  site of that key. `scripts/bc2cpp/source_review_check.rb` checks both directions on a full run:
  every site is annotated, and every gate annotation names a site.
- The central lists (`nomethod_reviewed.rb`'s constant, `strict_hints_reviewed.rb`, `proven_miss_reviewed.rb`'s list) and
  their update scripts are removed. `scripts/bc2cpp/source_review_sites.rb` dumps the sites of a full run and
  `source_review_migrate.rb` writes the comments for them.

The migration carried every existing NOMETHOD and PROVEN_MISS entry over with a reason that points back to ADR 0226 or
0275. The old lists had no per-entry reasons, so the migration does not re-review any site; it keeps the existing
review in the source.

## Consequences

- A review now moves with its code: refactoring a method keeps its annotations, and a change that removes a site makes
  its annotation fail the stale check rather than sit silently in a list.
- A review is visible where the code is read. The cost is comment lines in mrblib sources, and a few long lines where
  several sends share a line.
- The gate runs without a list file to regenerate, but it still needs a full run to check staleness. The fixture part of
  `source_review_check.rb` runs without a compiler.
- Continuation handling is a small rule (the annotation may sit above a backslash-continued statement). A future change
  to how mruby reports the line of a send could move sites; `source_review_check.rb` would then fail on the full run.
- STRICT_HINT was never enforced by `bc2cpp.rb` (only its listing was printed), and this change keeps that behaviour:
  the annotation check runs in `source_review_check.rb`, not in the build.
- `BLOCK_RETURNS` (ADR 0475) is unchanged: its reviewed set is empty, keyed by native declaration and file hash, not by a
  source line.
