# 0439. bc2cpp type check: an index on a possibly-nil receiver is an error unless a nil check comes first

Date: 2026-10-13

## Status

Accepted. Adds TC1005 to the type check (ADR 0412).

## Context

A receiver the flow leaves nilable (its class set includes nil) gets a nil test at the index site (NILABLE_RECEIVER,
ADR 0296). Without a dominating nil check, a nil receiver raises at run time. The type check reported nothing about
that. Plain sends on nilable receivers are a separate question and are not covered here.

## Decision

- GETIDX and SETIDX (`x[i]`, `x[i] = v`) on a receiver whose flow mask includes nil are recorded at the site
  (`CodeGen#note_unguarded_index`).
- A nil check before the index narrows the register out of the mask (`if x`, `return unless x`, `x&.` on the
  non-nil edge, numeric_flow.rb), so the site is not recorded. A check after the index does not help.
- The recorded sites are appended to the type-check facts after compilation (`TypeFacts.append_nilable_index`) and
  reported as `error: ... [TC1005]` by `scripts/bc2cpp/type_check.rb`, which exits 1.
- Only the type check reports this. The build's code is unchanged, so generated C++ is byte-identical.

## Consequences

- An engine that indexes a possibly-nil receiver fails the type check until each site has a nil check. The count is
  measured in the PR that adds this check.
- `[]=` cannot take `&.`, so a write site needs an explicit nil check.
