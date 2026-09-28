# 0241. Resolve self-calls in compiled module-function bodies

Date: 2026-09-28

## Status

Accepted

## Context

`module_function` installs a singleton copy that shares its source body with
the module's private instance method. Calls to that copy run with the module
object as `self`. bc2cpp could compile the shared body but left its bare calls
dynamic, and it rejected direct calls to the copy whenever the body observed
`self` or used a block.

## Decision

For an emitted module-function copy, resolve bare self-calls only to another
public copy on the same stable module singleton. Pass the current module object
as `self` to the shared compiled body. Require the module constant and singleton
lookup to be stable, the target body and call arity to compile, and the copy to
be emitted in this closed-world build.

## Consequences

Calls within LCF module functions such as `read_ber` and `write_ber` can avoid
method lookup while preserving the module receiver seen by the shared body.
Other receivers and module methods that fail the closed-world checks keep
ordinary dispatch.
