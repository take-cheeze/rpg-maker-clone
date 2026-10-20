# 0519. Prepare RBS contract indexes once per typing world

Date: 2026-10-21

## Status

Accepted

## Context

Each method's IR typing analysis reconstructed inherited ivar contracts and copied
all named-return keys. Receiver and callback lookups also traversed the same
hierarchy repeatedly. These inputs are settled before report collection, while
inferred arguments, source resolvers and query caches remain method-specific.

## Decision

Create `RbsSignatures::IrContracts` once in `IrTypeFeedback.collect`, after
signature application and hierarchy analysis. Snapshot named returns, method
presence, declaration maps and hierarchy inputs. Index ivars by declaring owner;
cache lookup order, inherited maps and method targets lazily with frozen results.

Share this explicit index with method typing and callback lookup. Never attach it
to a global cache or reuse it for another signature world. Reject an index whose
applied-signature object differs. Construct a new index if applied signatures or
the hierarchy change; preparation requires these inputs to remain settled.

Retain exact runtime owner lookup order, including overrides without their own signatures that hide
an inherited signature. A scalar ivar declaration removes an inherited element
bound. Keep receiver-relative `self` substitution in each call resolver, and
create a fresh `BytecodeIR::Types` for every method with its own inference inputs.

## Consequences

Repeated whole-table copies and hierarchy walks become once-per-world or
once-per-owner work. Lookup caches live only for one report collection and grow
with its queried owners and methods. Prepared records are frozen; method query
state remains separate. `BC2CPP_IR_PREPARED_CONTRACTS=0` retains the unprepared
path for complete engine and fixture comparisons.
