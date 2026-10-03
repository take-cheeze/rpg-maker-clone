# 0335. bc2cpp: preserve audited native copy and collection result classes

Date: 2026-10-04

## Status

Accepted

## Context

ADR 0334 leaves receiver-dependent native results unknown. A native copy preserves
its receiver class, while compact and join allocate known core classes. These facts
need allocation-helper audits and lookup checks: Ruby overrides can return anything,
and initialize_copy can mutate a copied object.

## Decision

For zero-argument native dup, preserve only known receiver class bits (including nil).
Require closed-world singleton freedom, native-only safe lookup for the name, and
complete pinned class.c and kernel.c sources, with both helpers present. Any unknown
native source, Ruby override, installer or unsafe lookup withdraws the proof.
The audited allocation preserves the original class; initialize_copy's return value
is ignored. Its effects remain observable because the original call still runs.
Do not copy element identities, frozen-table shapes or other allocation metadata.

For an exact Array receiver, compact returns Array and join returns String. Require
the existing NativeCoreDirect registration and wrapper audits and override-safe lookup.
Pin the complete core Array source for join and both Array-ext and its core allocation
helper for compact. Existing exact to_a and bytes facts also require their full source
pins. Unknown receivers and subclasses gain no exact-core contract.

BC2CPP_NATIVE_COLLECTION_RESULTS=0 disables the new dup, compact and join facts.
The existing native-class-results switch continues to disable exact core facts.
Compiler caches are classified as compilation-wide state by the lifecycle check.

## Consequences

The shipped Wio census changes from 2,845 to 2,844 cached sends, with ivar pools
189 to 190, argument pools unchanged at 136, nil-receiver helpers 921 to 923 and
exact-index arms 1,025 to 1,026. ADRs 0332–0335 remove 80 sites from the original
2,924. This measures generated dispatch sites and makes no runtime-speed claim.
With the collection switch off, shipped C++ is byte-identical to ADR 0334 output
(SHA-256 b497ae56b363fe00b795a52d88951a088e730fadfb447929dcdfda5000ede684).
Compact and join expand supported contracts without additional census savings here.

The collection check covers source and helper withdrawal, Ruby overrides, singleton
creation, the kill switch and compiled/interpreted parity, including an initialize_copy
callback returning another class. Full-core and 32-bit builds exercise compact;
the minimal core library has no Array-ext registration, so its parity harness runs
compact only when registered. Seven mutants and an unmodified control verify the
source, helper, lookup and switch boundaries. CI runs these checks in call-facts
and the runtime fixture in bc2cpp-width (int32).

Native setter constraints, dynamic caller completeness and unknown collection
element classes remain independent future proofs.
