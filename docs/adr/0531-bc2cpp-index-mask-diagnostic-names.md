# 0531. Reuse immutable bit positions for mask diagnostics

Date: 2026-10-21

## Status

Accepted

## Context

Class-mask reports scan every registered class with Integer#anybits?. A wide
class bit can allocate a temporary integer for each test. Numeric-mask reports
also rebuild the same primitive-name hash for every call. These reports run
throughout full-engine type-fact collection.

## Decision

Reuse native_result_class_bits, the existing immutable snapshot of class names,
bits and bit positions. Test Integer#[] at each named class position and skip
the appended core entries: primitive names already come from numeric naming.
Retain snapshot order rather than sorting selected classes. Take the snapshot
after numeric_mask_name, since the Symbol lookup may register a class. Its
existing table identity and size checks cover growth and probe rollback.

Keep primitive names and positions in one frozen table. Preserve the existing
LCF, private-shape and Symbol handling, including negative masks' sign-extended
bits. Return fresh joined strings as before; do not cache or freeze diagnostic
results.

## Consequences

Repeated reports allocate fewer temporary collections and wide integers. The
class decoder still scans its immutable snapshot, and LCF/private-shape naming
keeps its existing implementation. No inference state or oracle result is
cached. Differential host checks compare exact strings against the previous
algorithms for signed masks, lazy registration, private and LCF kinds, registry
growth, same-size replacement and probe rollback.
