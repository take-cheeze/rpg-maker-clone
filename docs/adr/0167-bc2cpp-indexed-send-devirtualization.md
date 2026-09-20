# 0167: Devirtualize indexed reads through exact compiled classes

Date: 2026-09-21

## Status

Accepted

## Context

mrbc emits indexed reads as `GETIDX` or `GETIDX0`. bc2cpp already specializes
the built-in Array, Hash, and String paths, but a custom receiver such as
`Game::Actors` fell through to `mrb_funcall("[]")` even when whole-program
analysis traced it to an exact compiled class. This left user-defined indexer
calls dynamic despite the same class-exact proof being usable for ordinary
TYPED sends.

## Decision

For a non-container indexed read, ask the existing send compiler to emit the
`:[]` call with the actual receiver and index expression. Keep that output only
when it is a TYPED call backed by an exact traced class. The generated code
checks the runtime receiver class, calls the compiled method on a match, and
uses Ruby dispatch otherwise. If tracing or target compilation fails, preserve
the existing Array/Hash/String fast paths and dynamic fallback unchanged.

Apply the same rule to `GETIDX` and `GETIDX0`; the latter supplies its literal
zero argument. The synthetic regression check covers both opcode shapes and
checks the class guard and fallback.

## Consequences

Known custom indexers can bypass method lookup while preserving overrides and
unrecognized runtime receivers through the existing fallback. This does not
change indexed writes (`SETIDX`) or builtin container handling.
