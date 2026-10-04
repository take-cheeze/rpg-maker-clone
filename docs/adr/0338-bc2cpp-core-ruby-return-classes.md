# 0338. bc2cpp: specialize core Ruby collection return classes

Date: 2026-10-04

## Status

Accepted

## Context

Native result audits leave Ruby collection producers such as map and select
unproved. A name-wide return table cannot distinguish a block-present collection
result from a no-block Enumerator, or an engine method with the same name. A
block's break can replace the call's value, so NumericFlow previously treated
every SENDB/SSENDB result as unknown.

## Decision

Add a context-specific exact-class analysis of the selected core Ruby bytecode.
An exact Array, Hash or Range receiver selects a definition through the existing
core arm ancestry and alias index, including ordinary core registry definitions.
The same native registration, outside Ruby, prepend, unresolved mixin and dynamic
installer exclusions apply. Project replacements on the lookup chain withdraw
the proof. Source edits are analyzed as new bytecode rather than accepted under
a method-name contract or a source digest.

Before the driver drops interpreted-only core definitions, retain their lookup
pairs and aliases as opaque entries. An excluded, conditional or accessor method
can still intercept an inherited method at runtime. Unmodelled/conditional core
aliases and core Ruby installers also withdraw lookup; computed installer names
withdraw all new facts. Static native helper results obey these exclusions too.

Admit only zero positional arguments and a callee signature with no positional,
rest or keyword parameters. SEND0/SSEND0 encode zero arguments without an argc
operand. A block-carrying call must have a dominating BLOCK writer, including
dominating MOVE chains, and no BREAK anywhere in that block's descendants.
Unknown/forwarded blocks, lambdas, non-dominating merges, splats and keyword calls
stay unknown. Caller nonlocal return leaves the call without a result and remains
part of the existing method-return join. Callee BREAK/RETURN_BLK descendants
withdraw this analysis, since their return registers need another child context.

A separate NumericFlow oracle seeds self with the proven receiver class and the
explicit block parameter with nil or a truthy opaque marker. The marker uses EXC
only for truthiness and cannot be exported as a result class. No block parameter
means no incoming local gets that marker. The oracle accepts literals and existing
audited native/copy results, while treating pooled arguments, constants, ivars,
upvars, block sends and growing Ruby return facts as unknown. Captured writes
retain NumericFlow's opaque-register refusal. This prevents an extra dependency
cycle into the whole-program return fixpoint.

Join every reachable method return, and export only a nonempty subset of the exact
Array/Hash/String bits. A nilable receiver can shed nil only when the existing
nil-unanswerable proof establishes that branch raises. Ordinary numeric oracles
still refuse block sends; only the exact-class oracle supplies the new guarded
block-result proof. BC2CPP_CORE_RUBY_RESULTS=0 withdraws all these facts.

## Consequences

The fixtures prove Array results for collect/map, find_all/select, reject and
partition on the admitted receiver paths, and Hash results for Hash#to_h and
Enumerable#tally. They check a stored collection result, nil receivers, next and
nonlocal return, and retain refusals for caller/nested break, missing/forwarded
blocks, source changes, captured writes, project overrides, aliases, mixins and
dynamic installation. Native-backed entries/deconstruct remain outside this
core Ruby lookup proof.

Full-core interpreted/compiled comparisons and generated-code assertions run in
the call-facts job; ten mutants and a control verify the proof boundaries.
The width job also runs the fixture on 32-bit mrb_int. On a 64-bit-pointer macOS
host, that runtime comparison uses BC2CPP_BLOCK_DIRECT_ENTRY=0 because the existing
block entry representation assumes a function pointer fits mrb_int; Linux CI
already uses non-PIE binaries. Actual 32-bit targets have matching pointer width.

The measured Wio dispatch change and remaining work are recorded in
[core Ruby returns](../bc2cpp-core-ruby-returns.md). Nonzero arity, forwarded block
values, precise break-result joins, subclass receivers and recursive core return
specialization remain future work. Result facts preserve the original producer
call and its errors; they narrow subsequent consumers rather than replace Ruby
execution with an assumed collection.
