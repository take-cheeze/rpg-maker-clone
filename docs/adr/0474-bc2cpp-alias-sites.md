# 0474. bc2cpp: a class-body alias is a definition of the new name

Date: 2026-10-16

## Status

Accepted

## Context

On master's wio shipped pass, 34 call sites stay dynamic as `KEPT dynamic_install`. Every one of them calls a name
that an `alias_method` in mruby-rgss installs, because `CodeGen#symbol_installed_names` counts both names of every
alias as installed at run time:

- 32 sites call `update` (Graphics, Sprite, Window, Viewport, ...). The name comes from `RGSS.effect_probe`
  (mruby-rgss `lib.rb`), which sampled a frame from inside `Graphics.transition`. It did that by opening
  `class << Graphics` in the method body, aliasing the native `update` to `_probe_update` and defining a Ruby
  `update` that called it, then aliasing it back afterwards.
  - Only `src/main.cxx`'s desktop `--rgss_effect_probe` flag runs that probe (a ctest under xvfb).
  - The wio build deletes it from its copy of `lib.rb` (`scripts/wio/strip_rgss_probes.rb`).
  - The closed-world shipped pass compiles the unstripped `lib.rb`, so the probe's aliases poisoned `update`
    for the whole engine.
- 2 sites call `sort` with a block (`Game::TextReveal#initialize`). The name comes from mruby-rgss
  `array_sort.rb`'s class-body `alias_method :_rgss_native_sort, :sort` (and `:_rgss_native_sort!, :sort!`).
  These keep mruby's sort under another name before redefining `sort`.

`lib.rb`'s class-body `alias_method :_rgss1_initialize, :initialize` (RGSS::Window) put `initialize` and
`_rgss1_initialize` in the set too, without a kept site today. The foreign gems' class-body aliases (mruby-io,
mruby-complex, mruby-stringio, mruby-onig-regexp) never counted. `collect_installed_names` skips mruby's own Ruby
(ADR 0264), and the closed world reads the foreign sources as outside Ruby, where only a non-literal definer
refuses (`RUBY_DYNAMIC`).

## Decision

1. **Class-body aliases are definitions.** `tools/bc2cpp/alias_sites.rb` recognizes these two forms in a class
   or module body of the engine's own Ruby (not top level, not a Struct block, not mruby's core Ruby):
   - `alias new old`;
   - `alias_method :new, :old`, sent with an implicit receiver, with both names `LOADSYM`'d straight into
     the argument registers.

   Neither may sit under a jump or handler range (`DefineMethodSites.straight_line?`). A recognized site
   registers a `MethodDef(installer: :alias)` for `new` on that owner:
   - When `old`'s live definition on that owner, as the walk has seen it so far, is an engine Ruby `def`,
     `new` gets a copy of that body: the irep tree under `<label>~al<i>`, sharing its instructions. The copy
     is compiled and registered like any method, with the visibility the definition had at that point. A
     later `def old` replaces only `old`, which is Ruby's semantics: the copy was taken from the definition
     the walk had reached.
   - A body that uses `super`, `ARGARY`, `__method__` or `binding` is not copied. In an aliased method these
     answer the original name, and a copy registered under `new` would answer `new`.
   - A definition a branch can skip (`CoreDefs.conditional_def_labels`) is not copied.
   - In an owner with a prepended or unresolved module the copy is dropped after the walk, since the module
     answers `old` first.
   - In every other case (a native, core Ruby, inherited, attr_* or installer `old`), `new` is a definition
     with no body the compiler knows (`irep: nil`), dispatched by name like a Struct member. Its visibility is
     mruby's private-by-name rule. The name is now a known method of that class instead of one installed at
     run time, so a call to it can be an owner call (ADR 0468): a lookup on the proven owner instead of a
     by-name dispatch.

   `AliasSites.settle`, run by `bc2cpp.rb` after `DefineMethodSites.settle`, keeps the definitions only in a
   closed world.
   - An `alias_method` site is kept only when `ClosedWorld#alias_method_trusted?` holds: no global refusal,
     and nothing defines, aliases, undefines or spells `:alias_method`. That is the define_method test of
     ADR 0288, now `installer_intercepted?(name)`. The `alias` keyword is an opcode nothing can redefine.
   - Any other definition of `new` on the same owner (a `def`, another alias, a `define_method`) drops the
     alias, together with its copy.

   `collect_installed_names` skips a settled site, both names. `old` was never changed by the alias.
   `DefineMethodSites.settle` now handles only `installer: :define_method`.
2. **The effect probe hooks instead of aliasing.** `Graphics` gets
   `attr_writer :transition_frame_hook` on its singleton. `transition` calls the hook after each frame it
   draws (`@transition_frame_hook&.call`). `RGSS.effect_probe` sets the hook to a lambda that samples the
   first frame, runs `transition(4)`, and clears the hook in an `ensure`.
   - The sampled frame is the same, the first `update` inside the dissolve, since `effect_probe` has already
     returned unless the backend can snapshot, so `transition` takes its loop.
   - The `$rgss_probe_mid` global and its two lint allowances go.
   - The two baseline entries of the closed-world lint are regenerated away.
   - The wio strip script keeps working: nothing outside the stripped probes names them.

Everything else stays a dynamic installer: an alias in a method body, under a condition, in a loop or block,
with a computed name or an explicit receiver, an `alias_method` whose answer goes to a visibility send
(`private alias_method :a, :b`, which the registry does not attribute), at top level, or in a singleton class of something other than
the body's own `self`.

## Consequences

- Expected effect on the wio shipped pass: the `update` sites close with the probe hook and the `sort` sites
  with the settled `array_sort.rb` aliases. All 34 `KEPT dynamic_install` sites close, and
  `symbol_installed_names` of the engine becomes empty (measured on the closed-world sources with the registry
  alone; CI measures the pass).
- `scripts/bc2cpp/alias_method_check.rb` (in the `bc2cpp-build` job) checks three things.
  - The registry: each shape, the copy taken from the definition before a later `def old`, and each refusal
    and settle withdrawal.
  - The generated code: direct calls to an alias of a Ruby method, and a method-body alias that stays a send.
  - The interpreted and compiled answers on real mruby, for an alias of a Ruby method, an inherited method
    redefined after the alias, a core method, a private alias, `__send__`, strict arity, and a refused
    method-body alias.
- Many existing fixture checks used a class-body alias as their "dynamic installer" world. Where a world's
  point is the withdrawal, it now spells the alias in a method body, which stays one.
- Pre-existing and unchanged: two engine `def`s of one name on one owner emit two C++ bodies of one symbol.
  Owner registration also replaces a method that a later alias or define_method on that owner replaced in the
  interpreter. Settle withdraws an alias that collides with a `def`, so neither gets worse here.
- Residual risk: the trust test is lexical, as for ADR 0288. A copied body is compiled independently of
  `old`'s, so the two can specialize differently, as two `def`s with one body would.
