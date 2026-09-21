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
implementations. It accepts only zero-argument methods whose registered
implementations all have the same, single return expression, and whose
expression uses only a small allowlist of pure mruby value helpers. The first
consumer generates the `!` call-site expression from mruby's own BasicObject C
implementation. Existing whole-program name and call-arity checks remain in
force. Any unsupported body, frame access, or conflicting registration is
excluded and keeps ordinary Ruby dispatch.

## Consequences

New source-derived fast paths can be added without copying their behavior into
bc2cpp, and the compiled output follows the mruby C implementation. The
accepted C subset is intentionally small; methods with branches, locals,
argument extraction, allocations, or frame-dependent helpers need an explicit
safe adapter or broader analysis before they can be generated.
