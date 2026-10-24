# bc2cpp: `ensure`, and a `rescue` inside it

`ENSURE_RAII_SUPPORT` (`tools/bc2cpp/codegen_rescue.rb`,
`recognize_ensure_region`) compiles `begin BODY ensure ENSURE_BODY end` as
a C++ scope holding a `bc2cpp_ensure_guard`. The guard's destructor runs
`ENSURE_BODY` on every exit: falling off the end, a `goto` out, or a C++
exception carrying a Ruby `raise`. The body runs under `mrb_protect_error`,
so nothing escapes the destructor. An exception the ensure body raises
supersedes the one in flight, as in Ruby.

## A rescue inside the ensure body

`ENSURE_NESTED_RESCUE` adds one shape: a single `begin X rescue C ... end`
inside the ensure body. mruby-io's `IO.open` closes its io this way:

```ruby
begin
  yield io
ensure
  begin
    io.close unless io.closed?
  rescue StandardError
  end
end
```

In the ensure lambda, the protected range `X` becomes its own lambda under
`mrb_protect_error`. On an error, `$!` and the handler's register are set, as
`EXCEPT` does, and control jumps to the handler. The handler's `RESCUE`,
`JMPIF` and `RAISEIF` compile as they do anywhere. An exception the clause
doesn't match is raised again into the guard's own `mrb_protect_error`, so
it supersedes the one in flight.

The rescue must have the shape `recognize_rescue_regions` reads (a class
clause chain), lie wholly inside the ensure body, and keep every jump of its
protected range inside it. The protected range may hold none of the ops the
ensure body refuses. Any other mix (a rescue around the ensure, two rescues
inside it) keeps `#error`.

## A jump onto the protected range

`ENSURE_ENTRY_LABEL`: a jump from before the range onto its first
instruction, such as `return io unless block` right before `IO.open`'s
`begin`, enters it the way falling in does. Its label is emitted ahead of the
guard's scope, since a `goto` past the guard's initialization would be
ill-formed.

## Fibers

A compiled method that yields runs its block from a C frame. A `Fiber.yield`
inside that block raises `FiberError` (can't cross C function boundary), as
for any compiled method that yields. The engine creates no Fibers.

## Check

`scripts/bc2cpp/ensure_nested_rescue_check.rb` asserts that the
`IO.open`-shaped fixture and mruby-io's own `IO.open` compile, and that the
other mixes don't. It compares interpreted and compiled runs for a close that
succeeds, raises a `StandardError` (rescued) or raises a non-`StandardError`
(supersedes the block's exception), `$!` after the call, `File.open`,
`GC.stress`, and calls inside a Fiber.
