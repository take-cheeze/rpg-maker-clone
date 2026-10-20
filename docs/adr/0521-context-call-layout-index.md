# 0521. Index context call layouts by bytecode site

Date: 2026-10-21

## Status

Accepted

## Context

Dispatch and effect queries repeatedly decode a call frame during context graph
solving. Receiver mode, argument count and keyword-name producers depend on the
unchanged bytecode. Receiver masks and argument/keyword values change across
contexts and solver rounds. Reaching-definition queries already cache traversal
results, but return fresh public definition copies to each caller.

## Decision

Within each `IrContextResults` engine, index call layouts by body identity and
instruction index. Cache frozen receiver mode, base register, argument count and
ordered keyword-name/value-register pairs. Retain duplicate keyword pairs in
source order so later values still overwrite earlier ones.

Keep the existing reaching-definition options and budget. A keyword must have
exactly one non-entry LOADSYM producer. Cache static refusals for splats,
ambiguous definitions and unsupported producers; no context graph decision is
cached. Copy keyword strings before freezing them. Bytecode bodies must remain
unchanged for the engine lifetime.

Every frame reads the current node receiver and state, constructing fresh
argument and keyword containers. In particular, bottom and unknown values are
never retained in layouts. Graph admission, fixpoint rounds and effect traversal
keep their existing limits. `BC2CPP_IR_CALL_INDEX=0` rebuilds layouts on each call.

## Consequences

Repeated context calls avoid accessor lookups, definition copies and keyword
producer decoding. The index lives only as long as its engine and grows with the
queried bytecode sites. Host checks cover changing values, independent body
identity, duplicate keywords and conservative refusals. Complete fixture reports
are compared with indexing disabled, including graph and round limits.
