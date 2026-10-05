# 0351. Use call inputs in receiver-scoped return analysis

Date: 2026-10-05

## Status

Accepted

## Context

The class-scoped lookup of ADR 0346 selects the method for an exact receiver,
but the selected body's return analysis reads global argument pools. A helper
that returns its argument loses its class when different callers pass different
classes. A method returning self also needs the caller's actual receiver class,
including when a subclass inherits the method.

## Decision

After the global facts settle, seed lexical self for method frames of a declared
instance class with no descendants. Require one owner for the bytecode body,
including method copies; reject shared bodies, modules and nested closures.
Normalize implicit-self calls using this exact class. Global argument pools
remain unchanged in this lexical flow.

Also analyze a selected user-method body with a local
ContextOracle seeded with the exact receiver mask and the caller's positional
argument masks. Admit this context only for a fixed mandatory arity matching
the call, with no optional, rest, trailing, keyword or block parameters and no
nested ireps. Other shapes retain the existing scoped analysis.

Use the existing CFG-aware NumericFlow and captured-register exclusions. Load
self from the context, treat RETSELF as the actual receiver, and normalize
implicit-self calls to that receiver before asking the result oracle. Join all
reachable returns; accept only one exact user or core class. Unknown, nilable
and mixed results contribute no exact class.

Cache by receiver class, method name and the complete argument mask vector.
An active specialization contributes no result; only the invocation that added
an active key removes it. Local states do not enter the global class or argument
pools. Existing closed-world lookup, outside-definition, installation and
singleton exclusions apply before the body is selected.

`BC2CPP_CALL_CONTEXT_RESULTS=0` disables lexical-self seeding, call-input
specialization and its core result admission. No compiled method specialization or runtime type assumption
is introduced.

## Consequences

Exact receivers can survive identity helpers, forwarding methods and nested
calls even when global argument pools contain several classes. An inherited
self-return keeps the subclass, preserving later override lookup. Closures and
flexible argument shapes remain outside this context analysis.

The focused check compares interpreter and compiled results and exercises
unknown, mixed, nilable, recursive, wrong-arity and nonlocal block-return cases.
Its eleven mutants withdraw the switch, lexical subclass check, cache arguments,
input masks, actual self, arity, parameter shape, closure, LOADSELF, outside lookup and
implicit-self conditions. Existing return-class and call-result suites cover the lookup exclusions.

## Measurement

On base `8b011eae`, the Wio analysis inputs give 2,769 cached dispatch sites with
the feature disabled and 2,765 enabled. POLY remains 897 and compiled entries
remain 3,056. The first call-input-only extension gave no shipped reduction;
adding lexical-self flow removes four guarded fallback sites. These are static
counts, not a runtime speedup measurement.
