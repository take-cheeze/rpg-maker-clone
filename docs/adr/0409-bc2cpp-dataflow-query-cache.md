# 0409. Reuse bc2cpp bytecode dataflow queries

Date: 2026-10-12

## Status

Accepted

## Context

A CPU profile of full-source rpg2k generation attributed about 17% of samples
to reaching-definition walks and 8% to dominance checks. Instrumentation
counted 89,399 reaching queries (22,405 distinct) and 116,272 dominance queries
(19,777 distinct). Analysis probes and repeated receiver proofs rerun the same
walks over fixed bytecode.

## Decision

Memoize both queries on their `BytecodeIR::Program`, which already owns a
cached CFG for one decoded body. Key reaching queries by instruction, register,
opaque-register contents and every proof option. Key dominance by write, use,
register and opaque-register contents. Cache nil and false answers too.

Bypass caching for a mutable opaque set or a caller's refusal-diagnostic Hash.
Snapshot key strings and frozen opaque-set contents. Keep definition results
private and return deep copies of their mutable arrays, structs and register
strings. Limit each cache to 1,024 answers per body; subsequent distinct queries
still run normally. This bounds retained answers for exhaustive test/report
queries without evicting early repeated codegen queries.

## Consequences

On x86_64 Linux with CRuby 3.4.9 and YJIT, alternating baseline and cached
full-source generation emitting the rpg2k owners took:

| Mode | Wall time, two runs | Peak RSS, last run |
| --- | --- | --- |
| Baseline | 15.10 s, 15.03 s | 429,680 KiB |
| Cached | 13.49 s, 13.13 s | 436,308 KiB |

The emitted C++ matched byte for byte. The setup used
`closed_world_mrblib_srcs(root)`, default open-world proofs and
`SKIP_UNSUPPORTED=1`, without native-source overrides. These measurements
include the per-body retention limit and measure generation, not total CI.

The query semantics and proof refusals do not change. The existing dataflow
check retains its independent forward-fixpoint oracle, with focused cases for
cache reuse, state-cap separation, mutable caller inputs and refusal diagnostics.
Programs share no cache by label, and new decoded bodies get fresh answers.
