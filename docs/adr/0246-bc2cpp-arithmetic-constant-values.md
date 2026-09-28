# 0246. bc2cpp resolves bounded integer arithmetic constants

Date: 2026-09-29

## Status

Accepted

## Context

mrbc can preserve arithmetic involving constants as `ADD`, `SUB`, `ADDI`, or
`SUBI` bytecodes. `IntegerConstants` previously recognized only direct integer
literals and aliases, so a stable value such as `WIDTH = BASE + OFFSET` could
not be substituted at later constant reads.

## Decision

The constant analyzer follows only straight-line definitions of those four
bytecodes. Each operand must be a literal or another proven integer constant.
mruby's arithmetic bytecodes use their integer implementation for Integer
operands and dispatch only for other receiver types. The analyzer evaluates the
exact result and admits the assigned name only when it fits the cross-target
Fixnum range. An overflow, unresolved operand, branch entry, or other opcode
keeps the ordinary constant lookup.

## Consequences

Constant expressions involving `+` and `-` can now feed the existing GETCONST
and GETMCNST literal substitution. The proof does not extend to multiplication,
division, user-defined calls, or values outside the target Fixnum range.
`scripts/bc2cpp_integer_const_inline_check.rb` checks in-range chains and the
overflow boundary.
