# 0492. Stream register-use counts during declaration pruning

Date: 2026-10-19

## Status

Accepted

## Context

Unused-register declaration pruning runs for emitted methods, nested block
helpers and cleanliness probes. `String#scan(...).tally` allocates a string for
every occurrence and retains the whole match array until counting completes.
Skipping pruning in probes retains larger strings and increased GC time in
local measurements, despite allocating fewer objects.

## Decision

Use Ruby's standard `StringScanner#skip_until` to find the same whole-word
register references without materializing each match. Decode canonical decimal
indices into integer hash keys. Preserve leading-zero spellings as string keys
because identifiers such as `r01` and `r1` must remain distinct. Hash keys avoid
allocating an array proportional to a potentially large textual register index.

Retain the same pruning pass in all compilation paths. The scanner still counts
comments, string literals and address-taken locals conservatively. A differential
host check compares pruning against the previous rule over randomized text,
including Unicode word boundaries, leading zeros and wide indices.

## Consequences

The generator requires the standard `strscan` library, supplied with the Ruby
used for compilation; no project gem or runtime dependency is added. The pass
keeps less temporary text alive and does not change proof caches, diagnostics
or emitted C++.
