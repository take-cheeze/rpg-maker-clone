- **179 compiled RPG2000/2003 methods are no longer registered with
  `mrb_define_method` at all.** Their names can never be looked up in a
  method table at runtime: every real caller is already a direct `_impl` call
  in generated C++. So the `mrb_get_args` wrapper each registration kept alive
  is now dead, and the compiler drops it: -16,336 bytes of `wio_rgss_boot`
  bc2cpp flash in a clean A/B link. The proof is
  `tools/bc2cpp/static_dispatch_registrations.rb`. It is name-level and
  treats a name as dynamic by default. A name counts as reachable if any of
  these could look it up:
  - bytecode that can run, with the mrblib load phase modelled separately;
  - any string literal in generated C++;
  - `super`;
  - any string-pool literal or `"#{x}_suffix"`-style fragment;
  - any token in core, external or other-maker mrblib, tests, `scripts/`,
    `.github/`, `tools/` or native sources;
  - mruby's protocol names.

  The set is checked in as `tools/bc2cpp/static_dispatch_unregistered.rb`.
  `bc2cpp.rb` skips those names for wired owners, and
  `scripts/bc2cpp_prune_static_dispatch_registrations.rb` removed 144
  hand-written `register.cxx` lines. The new
  `scripts/bc2cpp_static_dispatch_check.rb`, in the bc2cpp CI job, re-proves
  every listed name on every run. bc2cpp.rb's "never called" diagnostic now
  counts `SENDB`/`SSENDB` sends too, and `registered.tsv` now rebuilds when
  any `tools/bc2cpp/*.rb` changes. See docs/adr/0203.
