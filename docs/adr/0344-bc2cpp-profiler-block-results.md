# 0344. Prove Profiler block results with separate capture and local frames

Date: 2026-10-04

## Status

Accepted

## Context

The receiver census on e50a09dc contains 1,630 unproven explicit-receiver sends.
Nineteen read `@map`; seventeen would lose their by-name line under the broad
receiver counterfactual. Their pool is dropped by constructor arguments, map
accessors and `RGSS::Profiler.section` results. The Profiler native returns its
block's value in every configuration, so result forwarding is a concrete first
step. It cannot by itself establish every map writer.

Runtime checks also expose two existing helper-frame problems: capture indices
can overlap local registers, and a C++ return from the separate block helper
cannot implement a return from the enclosing Ruby method. A result proof must
preserve the executed block's semantics.

## Decision

Pin the complete `mruby-rgss/src/profiler.cxx` source and audit every native
spelling from both the linked world and the supplied native-source census.
Reject Ruby definitions of either method name, even on unrelated owners: the
registry's owner for a qualified module reopen is not always its full path.
Existing installer, alias, opaque core and mixin exclusions also apply.

Resolve the receiver's constant path with dominance and lexical lookup checks.
The two native Profiler bindings are mutually exclusive preprocessor branches;
the pinned source audit permits that exact binding count through the existing
native constant stability check. Other callers retain its single-binding default.

Analyze a dominating, zero-parameter literal block using NumericFlow. Entry
arguments, captures, constants and ivars are unknown. Literals, constructors,
selected core results and existing name return facts can prove normal returns.
Reject descendant breaks and nonlocal returns. Preserve the empty lattice set
while callee facts grow; reject every result containing OTHER.

Record dependency edges from the block and its descendants to the enclosing
Profiler caller. Invalidation follows those edges with a visited set. The block
flow is recomputed without an additional cache, so changed or dropped callee
facts cannot leave stale caller results.

Separate helper locals from capture indices, pass captures as slot pointers and
bind them by reference. Nested helpers use the parent's register offset.
Nonlocal returns retain the existing block fallback and its method-return token.
Deep captures that cannot be represented retain the fallback.

## Consequences

Map-loading and party-construction blocks can retain Game::Map and Game::State
facts. The broader `@map` pool still requires accessor and constructor proofs.
The result kill switch is `BC2CPP_PROFILER_RESULTS=0`; it does not reintroduce
helper-frame bugs.

Generated-code checks cover withdrawal and fixpoint cases. Full-core runtime
checks compare enabled and disabled profiling, capture reads/writes, nested
captures, nil and nonlocal exits against the interpreter. Mutation checks cover
source pins, lookup closure, lexical resolution, binding counts, unknown arms,
empty facts, dependency invalidation and helper frames.

The same-tree control/enabled Wio census on e50a09dc plus these helper repairs
reduces cached calls from 2,774 to 2,772 and sites capable of reaching by-name
dispatch from 8,400 to 8,398. Body sends fall from 2,350 to 2,348; block funcalls
stay 400, index helper callers 2,246, numeric helper callers 3,264 and equality
helper callers 110. The removed fallbacks are startup map width and height;
no calls relocate. Argument pools grow from 136 to 138. The full reviewed error
census remains 2,931 keys and 4,186 sites, with startup map width/height replacing
startup state map=/map_id keys after reviewing their receivers.
