# 0172: Carry Array element types into fallback each_with_index blocks

Date: 2026-09-21

## Status

Accepted

## Context

Standalone block cfuncs can preserve proven Array element classes for
`Array#each`, but `Array#each_with_index` still loses the same fact. The
mruby implementation forwards the yielded Array element as the first block
argument and the index as the second.

## Decision

Extend fallback element specialization to zero-argument `Array#each_with_index`
blocks with exactly two mandatory parameters. Reuse the Array receiver and
element-class proofs, and hint only the first block argument. The existing
runtime exact-class guard and Ruby dispatch fallback remain in place. The
index and all other iterators remain untyped.

## Consequences

Calls on proven elements in fallback `each_with_index` blocks can use guarded
direct dispatch. Unknown Array elements and non-Array iterators continue to
use dynamic dispatch. Regression checks cover typed and untyped Arrays.
