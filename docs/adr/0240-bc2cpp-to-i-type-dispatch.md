# 0240. Use native type dispatch for zero-argument `to_i`

Date: 2026-09-28

## Status

Accepted

## Context

The generator already had native conversion code for zero-argument `to_i`,
covering Integer, Float and String receivers with ordinary dispatch for other
types. A separate native-expression registration caused call sites to miss
that path, leaving common conversions dynamic despite the existing runtime
type dispatch.

## Decision

Select the native `to_i` emitter when the closed-world registry confirms the
built-in implementations have not been replaced. Keep its per-type behavior,
including the dynamic fallback for unsupported receiver types and String
subclasses.

## Consequences

The built-in conversions no longer need method lookup at those call sites.
Unsupported types and numeric edge cases retain ordinary Ruby dispatch.
