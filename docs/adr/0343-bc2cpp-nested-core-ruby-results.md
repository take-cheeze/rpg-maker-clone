# 0343. Nested core Ruby collection result proofs

Date: 2026-10-04

## Status

Accepted

## Context

ADR 0338 analyzes the actual bytecode of a selected core collection method.
Its static oracle previously treated every block-taking helper call as unknown.
Array#sort_by ends in a literal-block call to collect!, losing a provable Array
result at that boundary.
Its shipped callers obtain their input through Range#to_a, whose numeric helper
and superclass fallback also need complete result facts.

## Decision

Let the static oracle reuse the selected-core-body analysis for zero-argument
block calls whose receiver class it knows exactly. Require the existing complete
lookup, literal caller block, captured-write and nonlocal-exit audits at every
level. Disable name-wide unknown-receiver analysis inside this recursion.

Carry an immutable set of active specializations keyed by bytecode identity,
receiver mask and block presence. A repeated key contributes no result fact.
No growing caller pool or return table enters the oracle, and no global mutable
recursion state or new cache is introduced.

For an argument-free super call with no supplied block, select the next core
definition on the known receiver chain and analyze its actual bytecode. Refuse
additional included modules that the fixed chain does not represent. This is
an optional NumericFlow oracle hook; other oracles still treat super as unknown.
Aliased calls whose invoked name differs from the selected definition's name
retain unknown super results; method identity affects the VM's super lookup.

Audit the pinned native Range#__num_to_a body as returning exactly Array or nil.
Pin its Array allocation helper too. Integer and bigint ranges allocate arrays;
unsupported endpoints return nil and the Ruby Range#to_a body uses super.
Analyze both paths, preserving the nil fallback rather than assuming numeric
endpoints. Original calls, errors and width-sensitive arithmetic still execute.

`BC2CPP_CORE_RUBY_NESTED_RESULTS=0` restores the previous block-call oracle.
The broader `BC2CPP_CORE_RUBY_RESULTS=0` switch still disables the whole proof.

## Consequences

The outer method and its helper calls still execute. Only later dispatch sites
can disappear when the result class becomes proven. The result harness covers
actual sort_by behavior, project/core helper overrides, recursion and nested
caller breaks. Mutation checks withdraw the switch, lookup and actual-bytecode
return conditions independently.
Runtime parity exercises integer and String ranges. Native audit checks cover
changed range and allocation sources, omitted linked inputs, erased nil returns
and the native fact switch.

The same-tree Wio comparison against 959773b8, with the workspace's existing
native submodule contents as in ADR 0342, reduces cached calls from 2,776
to 2,774. The full dynamic-site count, including callers of dispatch-bearing
helpers, drops from 8,404 to 8,400. Three sort_by block fallbacks in
Game::Transition#compute_block_order and the size fallback in
Game::Transition#block_count_through disappear. Two index helper callers become
inline by-name fallbacks; these are relocations and contribute no removal.
Ordinary send lines therefore rise from 2,349 to 2,350, block-call lines drop
403 to 400, and index-helper callers drop 2,248 to 2,246. Numeric helpers (3,264
callers), equality helpers (110) and other body funcalls (30) stay unchanged.
One additional ivar pool and two exact-index arms are proven. These are static
site counts, with no runtime speed claim.

Two isolated candidate changes were measured before this combination. Nil in
native expression unions and nested collect! results alone each produced zero
shipped reductions. The nil extension was discarded; the nested result analysis
is needed together with the Range input proof to remove the shipped fallbacks.
