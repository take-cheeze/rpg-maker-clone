# Unregistered compiled methods

A compiled method needs a method-table entry only if something can look it up
by name at runtime. When every caller reaches it through a direct `_impl` call
in generated C++, bc2cpp leaves it out of the table: no `mrb_define_method`
call, and no `mrb_get_args` wrapper kept alive for it.

## What decides it

`tools/bc2cpp/static_dispatch_registrations.rb` proves each name. The proof is
name-level and its default answer is "dynamic". A name stays registered when
any of these could look it up:

- a send in bytecode that can run (a fixpoint, with the mrblib load phase
  modelled separately);
- a C string literal in the generated C++, outside the name's own
  registration;
- `super`;
- a string-pool literal or a `"#{x}_suffix"`-style fragment;
- a token in core, external or other-maker mrblib, tests, `scripts/`,
  `.github/`, `tools/` or native sources;
- one of mruby's protocol names.

Only RPG2000/2003 internal owners qualify.

The fragment and pool-literal rules also cover computed reflection: for
example `LCF.field?`, which calls `obj.respond_to?(name)` with a field name
from data, keeps every name that appears as a literal or fragment. A name
built at runtime from pieces that appear nowhere as a literal is the one
case this proof cannot see. Verify mode below exists to catch it.

## The two lists

- `static_dispatch_unregistered.rb`: names safe in every build.
- `static_dispatch_unregistered_closed.rb`: further names that are safe once
  the closed world's direct calls replace by-name sends. Builds with
  `BC2CPP_BUILD_NAME=closed` (`scripts/bc2cpp/closed_build.bash`) apply
  both lists.

Regenerate them with:

```sh
MRBC=<host mrbc> ruby tools/bc2cpp/static_dispatch_registrations.rb --write
MRBC=<host mrbc> ruby tools/bc2cpp/static_dispatch_registrations.rb --closed-only --write
```

The probe generates its C++ with `BC2CPP_BUILD_NAME=closed`, so the names
already on the closed list are missing from its registrations.
`--closed-only` therefore counts both lists as already unregistered. If it
did not, a rerun would drop every name on the closed list from the candidate
set and write a shorter list than the one checked in.

`BC2CPP_UNREGISTERED_EXTRA="Owner#name,..."` adds more names for a single
generation. It is meant for check fixtures, which have no place in the
committed lists.

## Verify mode

`BC2CPP_UNREGISTERED_VERIFY=1` (`build_config.rb`) defines
`BC2CPP_UNREGISTERED_VERIFY`. With it, each unregistered entry is registered
as a stub instead. The stub prints the message below and aborts:

```text
bc2cpp: UNREGISTERED_VERIFY: unregistered method looked up by name: Class#name
```

A plain build would raise `NoMethodError` at that point, and game code may
rescue it. The abort makes a lookup the proof missed fail loudly instead.
Use verify mode to run a game trace against the lists, for example
`BC2CPP_UNREGISTERED_VERIFY=1 scripts/bc2cpp/closed_build.bash <dir>` and
then `scripts/bc2cpp/trace_host.bash <dir> <game>`.

`scripts/bc2cpp/unregistered_verify_check.rb` checks the emitted
registrations, and checks both modes' runtime behaviour on a small host.
