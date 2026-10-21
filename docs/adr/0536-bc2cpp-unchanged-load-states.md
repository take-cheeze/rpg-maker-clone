# 0536. Share numeric-flow states across unchanged loads

Date: 2026-10-22

## Status

Accepted

## Context

Full-engine transfer instrumentation observed approximately 2.24 million copied
states, including 472,000 whose contents did not change. Repeated literal,
integer, pool, self, nil and string loads account for a subset of these copies.
State arrays also contain element, provenance and class-test metadata, so equal
class masks alone cannot establish that a rewrite has no effect.

## Decision

For these noncalling load kinds, retain the incoming read-only state only when
the effective destination mask and every affected metadata entry already equal
the normal transfer result. Still ask the oracle on every visit and collect
every register-write union. Otherwise use the existing copy-and-write path.

The immutable per-Program step table indexes possible register-provenance readers
from MOVE instructions. Flow-created states start with zero register provenance;
only MOVE can introduce a register provenance code, and joins cannot invent one.
Use that index to check load invalidation candidates. Hash/manual transfer
contexts retain their original copying behavior. Explicit helper callers without
the index keep the complete scan because their input states lack this invariant.
Class-test references are still checked independently.

Calls, slot refreshes, branches, handlers and other transfer kinds retain their
existing paths. BC2CPP_NUMERIC_LOAD_COPY_ELISION=0 disables the load optimization
for differential validation. Existing state-sharing mutation rules still apply.

## Consequences

Repeated abstract loads can avoid whole-array copies without changing oracle
ordering, writes, masks or invalidation. The structural index contains no oracle
answers and is reused only with its immutable bytecode Program. Frozen-input,
metadata invalidation, randomized-state and oracle-order checks compare against
the original writes and copied transfers. The pipeline comparison also toggles
the optimization when checking complete facts and receiver rows.

In a warmed same-tree full-engine comparison, enabling load sharing reduced
allocations from 98,758,812 to 98,501,925, saving 256,887 objects (about 0.26%).
Complete facts JSON, receiver TSV and diagnostic JSON were byte-identical.
Profiled times were 53.72s and 53.22s in one pair; this does not establish a
reliable wall-time speedup. Measurements used Ruby 4.0.5 with YJIT and StackProf
object sampling at one allocation in 4096 after a discarded cache-warming run.
