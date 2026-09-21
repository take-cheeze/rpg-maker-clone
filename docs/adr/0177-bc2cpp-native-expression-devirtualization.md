# 0177. Generate guarded devirtualization expressions from mruby C methods

Date: 2026-09-21

## Status

Accepted

## Context

bc2cpp already scans native C sources to account for method names, but native
method fast paths have been maintained as manually copied expressions. Calling
an arbitrary registered `mrb_func_t` directly is unsafe because methods that
use `mrb_get_args` read the active VM call frame. A useful generator therefore
needs to derive the implementation from the C source and reject methods whose
body or argument contract cannot be proven safe.

## Decision

Add a conservative source analyzer for native method registrations and
implementations. It extracts zero-argument, single-return bodies made from a
small allowlist of pure mruby value helpers. It links ROM tables to their
runtime class fields and instance tags, then generates exact-class paths for
Array/Hash `size` and `length`, Array/Hash/String `empty?`, and Hash
`to_hash`; it also generates Float `to_f` and Symbol `to_sym` from their
shared identity body, using immediate type tags rather than object-pointer
guards. It also generates the receiver-wide `!` expression from BasicObject's
implementation. Range `begin` and `end` use mruby's public Range accessors
behind exact-class guards. Float `finite?` and `nan?` use their registered C
predicates behind immediate Float tag guards.
Existing whole-program name, arity, override, prepend, and runtime class
checks remain in force.
Frame-reading methods, conflicting registrations, and unsupported bodies
keep ordinary Ruby dispatch.

## Consequences

New source-derived fast paths can be added without copying their behavior into
bc2cpp. Hash#to_hash is emitted only for an exact base Hash, preserving
subclass overrides through normal dispatch. Float#to_f and Symbol#to_sym use
their unambiguous immediate type tags; neither path treats an immediate value
as an object pointer. String#size and String#length remain dynamic
because `RSTRING_CHAR_LEN` is private to string.c and calls a private UTF-8
helper. The accepted C subset is intentionally small; methods with branches,
complex locals, argument extraction, allocations, or frame-dependent helpers
need an explicit safe adapter or broader analysis before they can be generated.
