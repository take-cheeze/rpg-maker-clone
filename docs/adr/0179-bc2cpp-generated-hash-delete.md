# 0179. Generate the guarded Hash deletion path from mruby core C

Date: 2026-09-21

## Status

Accepted

## Context

The one-argument source analyzer can substitute a compiled call-site argument
for `mrb_get_arg1`, but mruby's core `Hash#__delete` wrapper also clears the
current call-info method id before it invokes the deletion helper. Skipping
that write would change VM behavior; implementing deletion in bc2cpp would
duplicate hash mutation, equality, and frozen-object behavior.

## Decision

Recognize this exact call-info assignment as a side effect only in the
single-required-argument C body, and emit it as a comma expression before the
extracted return expression. Keep the generated method expression tied to
mruby's exact Hash registration and call the public `mrb_hash_delete_key`
helper. Do not generate public `Hash#delete`: mruby implements it in Ruby to
preserve its optional block behavior, and it calls the internal `__delete`.

## Consequences

The internal `__delete` send can use the C-derived deletion path on exact Hash
instances, with ordinary Ruby dispatch for subclasses and other receiver
types. Mutation checks, hash/equality behavior, and the required call-info
write stay owned by mruby core. Unsupported wrapper shapes remain on dynamic
dispatch.
