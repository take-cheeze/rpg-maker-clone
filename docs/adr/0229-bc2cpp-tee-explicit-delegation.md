# 0229. Give the stderr Tee a finite IO surface

Date: 2026-09-24

## Status

Accepted

## Context

ADR 0210 can replace a guard-chain fallback with `bc2cpp_nomethod` only when
the closed-world analysis can prove that no receiver can answer the name. The
`RGSS::ErrorReport::Tee` wrapper was the last class in the closed world that
defined `method_missing` and `respond_to_missing?`. Its dynamic forwarding
therefore made every non-`self` receiver retain a by-name fallback, even
though the runtime only uses the wrapper's write methods and `flush`.

## Decision

Keep the write methods (`write`, `print`, `puts`, and `<<`) as the Tee's
capturing boundary, and replace dynamic forwarding with an explicit `flush`
method that forwards to `@io`. Remove the hand-written
`respond_to_missing?` registration and the corresponding Wio reachability
exceptions. The normal generated owner-registration pass installs `flush`
when the method is compiled.

This deliberately narrows the wrapper's former catch-all compatibility. Code
that expects arbitrary IO methods through the Tee must now call the wrapped
`@io` or use an explicit method. The existing runtime has no such callers.

With the last `method_missing` class removed, the full Wio closed-world
codegen finds 3,070 proven-dead sites and 2,216 unique keys. The checked-in
`NOMETHOD_REVIEWED` set is regenerated from that run: 2,178 keys were added,
none were removed, and the review gate passes in both directions. The sites
are grouped under the existing Game, RPG2k, LCF, and RGSS owners; each key
remains guarded by the same compiler review mechanism from ADR 0226.

The hot-only RPG2K probe changes from 2,225 `bc2cpp_send` sites to 1,807,
with 418 newly proven sites emitted as `bc2cpp_nomethod`; its generated C++
source is 2,457,966 to 2,457,756 bytes. The hot-only RGSS source is
114,995 to 114,881 bytes, while LCF is unchanged at 145,890 bytes.

## Consequences

Closed-world builds can remove the fallbacks that were blocked by the Tee's
dynamic forwarding, and the review list makes the newly exposed branches
auditable. The explicit `flush` path preserves the existing CRuby and mruby
error-report checks.

The Tee no longer forwards arbitrary IO methods. The source and full-build
review probe are the compatibility boundary; a new delegated method requires
adding an explicit method and its regression coverage rather than restoring
`method_missing`.
