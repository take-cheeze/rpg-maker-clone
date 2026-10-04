# 0348. Join core Ruby results across exhaustive receiver classes

Date: 2026-10-05

## Status

Accepted

## Context

Collection chains lose result proofs when a receiver can be either Array or
Hash, even when both selected methods return Array. Existing receiver-independent
proofs cannot express every such specialization. An older Array return hint also
allowed an Array-only map inline region after Hash reject.

## Decision

Analyze each member of an exhaustive core receiver set with the existing
specialized core Ruby oracle and join the result masks. Require every member to
resolve and produce a modelled result. Retain the existing closed-world,
singleton, lookup, native-source, captured-write and caller block-exit gates.
Unknown or unsupported receiver members cannot use this specialization.

Complete core flow masks take precedence over older collection inlining hints.
A mixed Array/Hash receiver cannot enter an Array-only inline region.

`BC2CPP_CORE_RUBY_RECEIVER_UNIONS=0` disables the new specialization while
preserving receiver-independent results. Generated checks, mutation checks and
interpreter parity cover mixed receivers, method overrides, unknown members,
block breaks and the switch.

## Consequences

Array/Hash map results retain Array proofs through subsequent collection calls.
The analysis performs one existing specialization per possible receiver class.
Missing information remains a dynamic call. Collection inlining respects
exhaustive flow facts even when an older heuristic claims a narrower class.

The Wio census with the inlining correction present in both runs reports 2,776
cached sends with the union switch off and 2,775 with it on. Both have 892 generic
POLY sites and 3,056 compiled entry points. The earlier parent census had 2,773
cached sends: restoring safe dispatch increases the net count despite the new
result proof. These are static sites, not runtime frequency or speed measurements.
