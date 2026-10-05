# 0352. Join user-method results across exact receiver families

Date: 2026-10-05

## Status

Accepted

## Context

Call-context analysis selects one user method for an exact receiver. Inherited
methods may execute with several receiver classes, and CFG joins may retain
several exact constructor results. These sets can still select methods that
return the same class.

## Decision

Analyze each member of a set of two to eight exact user receiver classes through
the existing stable closed-world lookup and call-context analysis. Accept a
result only when every member proves the same single class. Unknown, nil, core
and unallocated class bits cannot be discarded. Unsupported or missing lookups
withdraw the result.

For a uniquely owned instance method, seed self with its declaring class and
all declared descendants when the hierarchy is enumerable, has no opaque or
wild members, and contains at most eight classes. A subclass override participates
in the join. Modules and shared method bytecode remain unproved.

At a `new` instruction, read the class constant from its input register before
any result join. Constant identity and standard `new`/`allocate` lookup must be
stable under the existing constructor audit. NumericFlow then joins each
instruction's result normally. This handles a constructor immediately before a
branch join without using the joined destination as its input proof.

`BC2CPP_USER_RECEIVER_UNIONS=0` withdraws these extensions. The older call-context
switch continues to control local receiver and argument specialization.

When all exact receiver members select the same compiled Ruby method definition,
emit a direct call through the existing arity, clean-body and emitted-owner gates.
The actual receiver remains self, so nested calls still observe subclass overrides.
When members select different compiled bodies, emit class cases for those
bodies with an exhaustive final direct arm. Uncertain members retain ordinary
dispatch. Every body must be emitted in this run or by a declared companion gem.

## Consequences

Agreeing class families can prove a chained receiver without narrowing the
method's global argument pools. The eight-class bound limits compiler work;
larger families retain existing dispatch. Mutation checks cover agreement,
member completeness, unknown bits, constructor lookup and outside replacements.

The same-tree Wio measurement on base `ba3a3ef0` removes one cached site
(2,786 to 2,785; POLY 911 unchanged): `DebugMenu#max_id` dispatches `to_h`
through the proven `Game::Switches`/`Game::Variables` class set. The focused
fixture removes four by-name send sites (15 to 11). Static counts are not
runtime speed measurements.
