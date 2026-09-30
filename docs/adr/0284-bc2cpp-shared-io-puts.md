# 0284. bc2cpp compiles explicit-receiver `puts` to one shared helper

Date: 2026-09-30

## Status

Accepted. Refines [ADR 0244](0244-bc2cpp-io-puts-model.md): the runtime target
check it introduced stays, the per-site fallback goes.

## Context

`puts` with an explicit receiver was the sixth most common cached-dispatch name
in the whole-program report (418 sites). Each site expanded to an inline
`mrb_io_puts_direct` guard, a by-name `bc2cpp_send` fallback, and a second
`bc2cpp_send` under `#else` for builds without mruby-io. 205 of the 209 sites
are `$stderr.puts` diagnostics; none is `$stdout.puts`. The 418 is therefore
two textual copies of 209 sites, only one of which is ever compiled.

The obvious idea is to prove `$stdout`/`$stderr` never leave the core IO and
drop guard and fallback. That proof does not hold:

- **`$stderr` is reassigned inside the closed world.** `RGSS::ErrorReport.install`
  (`mruby-rgss/mrblib/error_report.rb`) does `$stderr = Tee.new($stderr)`;
  `error_dump_install` in the desktop host calls it at start-up. The value set
  is at best `{IO, Tee}`, and showing `install` unreachable in a build would need
  a data-flow proof through the engine's computed-name `send` sites.
- **Open-world builds run user Ruby.** The rpgxp/rpgvx/wolf/mvjs script hosts
  evaluate a project's own scripts in the same VM (ADR 0017, 0023, 0030), and a
  script may do `$stdout = File.open(...)` or redefine `IO#puts`. The closed-world
  contract (ADR 0210) covers only psp/wio/maix builds, which admit no such gem.
- **Tests reassign both** (`scripts/*_check.rb`, `mruby-rgss/test/test.rb`).
- **A `$stdout`/`$stderr` write hook does not help.** An epoch bumped by a
  patched `mrb_gv_set` (`variable.c`) would only prove *identity*; the guard also
  has to prove that `IO#puts` still resolves to the C body (a Ruby override, a
  `prepend`, a singleton `puts`). That per-call method-identity check is what
  `mrb_io_puts_direct` already does, so the hook would add a hot-path compare to
  every global-variable write in mruby core and remove nothing.

A guard-free `puts` is therefore unsound in every build that matters, and a
proven-stable variant would need ErrorReport reachability, an `IO#puts`
override proof and a dead-code trap, for a saving of one method-cache probe.

## Decision

Keep the runtime check and move the fallback out of line.

- The preamble defines `bc2cpp_io_puts(M, recv, mid, argc, argv)` once. Under
  `HAVE_MRUBY_IO_GEM` it returns `mrb_io_puts_direct`'s result when the
  receiver's `puts` still resolves to mruby-io's registered body; otherwise, and
  in builds without mruby-io, it calls `bc2cpp_funcall_argv` (the same dispatch
  `bc2cpp_send` ends in).
- A site is `r = bc2cpp_io_puts(M, recv, mrb_intern_lit(M, "puts"), n, argv);`
  with the argument array built inline. The symbol cache turns the intern into
  `bc2cpp_sym`, so the name is still in the table the static-dispatch analyses
  read. The `#ifdef`/`#else` pair disappears from the site.
- A `puts` carrying a literal block (`@call_block_expr`) keeps the ordinary
  per-site dispatch, which passes the block.

No proof about `$stdout`, `$stderr`, `STDOUT` or `IO#puts` is assumed, so the
behaviour is the same in open and closed worlds. `scripts/bc2cpp_io_puts_model_check.rb`
compares compiled and interpreted runs against a full mruby with mruby-io,
mruby-stringio and mruby-eval: a plain `$stdout`/`$stderr`, `nil`, symbols,
integers, nested and empty arrays, an object with `to_s`, frozen strings, zero to
three arguments, `$stdout`/`$stderr = StringIO.new` inside the program, from an
interpreted script and from `eval`, an `IO#puts` redefined in Ruby, a user class
with its own `puts`, and a `puts` with a literal block. It also asserts a plain
call makes zero dispatches and a user-defined `puts` exactly one.

## Consequences

Whole-program report (wio closed world), before and after:

| | before | after |
|---|---|---|
| cached `bc2cpp_send`/`mrb_funcall_with_block` sites | 10954 | 10536 |
| of which `:puts` | 418 | 0 |
| generated C++ (`shipped.cxx`) | 473951 lines / 22013756 bytes | 472077 lines / 21967240 bytes |

The drop is a smaller, simpler emission and one shared fallback, not fewer
possible dispatches: a redirected `$stderr` still dispatches, now through one
function. Only the report's counting changes, since `puts` no longer appears as
a `bc2cpp_send` site; the 209 compiled sites had one fallback each before.
Runtime cost for a plain IO is unchanged (one call to the helper, then the same
method check and body).

Guard-free `puts` stays possible if a build ever forbids `$stderr` reassignment
(no ErrorReport, no script host) and proves no `IO#puts` override; that belongs
in the closed-world model (ADR 0210) with its own trap, and needs a Tee arm as
long as `ErrorReport` is linked.
