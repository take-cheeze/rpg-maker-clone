# Stubbed mrblib bodies

A build with the compiled gems (`RPGMAKER_BC2CPP=1`) still loads each engine
gem's mrblib (`mruby-rpg2k`, `mruby-lcf`, `mruby-rgss`) as bytecode: class
bodies, constants and every method bc2cpp does not compile need it. The
compiled gems' `gem_init` then installs each compiled method over its bytecode
definition, or removes the definition when the method is left out of the
tables (see [Unregistered compiled methods](bc2cpp-unregistered-methods.md)).
After that, a compiled method's bytecode body never runs.

So the build ships those bodies empty. `bc2cpp_stub_mrblib` (`build_config.rb`)
replaces each `rbfiles` entry of an engine gem with a build-time copy under
`<gem build dir>/mrblib_stubs/`. In that copy each listed method keeps its
`def` line and parameters, and its body becomes `raise ScriptError`. The
bytecode of the body, and every presym name only that body used, drop out of
the binary. Builds without the compiled gems are unchanged.

## Which bodies

Each compiled gem's generation writes `<symbol>_stubs.txt` beside its code, one
`Owner#name` per line (`MrblibStubs.stubbable`, `tools/bc2cpp/mrblib_stubs.rb`).
An entry is listed when its body is safe to empty. A body keeps its bytecode
when:

- it may run while mrblib loads, before any compiled `gem_init`. The proof's
  load-phase model decides that (`StaticDispatchRegistrations.load_phase`).
  Here it reads the core mrblib too, as the generation does, with every
  bytecode definition (`CodeGen.block_self_bodies`): the registry the
  generation compiles from has dropped the core definitions it keeps
  interpreted, and a body missing there would count as code that runs at
  load. The model counts
  `self` in a core method as a core object, and does not count `dup` or `clone`
  as making an engine instance: both copy an object that already exists. Either
  one alone would make the model assume engine instances at load (core
  `Hash#merge` calls `dup`), and then every body whose name load-time code sends
  is kept;
- loading copies its method: a `module_function` copy, the source of an
  `alias`, or a name a load-time `alias_method`, `define_method`,
  `instance_method`, `method` or `module_function` call takes;
- the entry is guarded (`CORE_BLOCK_GUARD`), which keeps the interpreted method
  and can run it;
- its `Owner#name` is not exactly one plain `def` in the registry.

The rewrite (`MrblibStubs.rewrite`, Prism) finds each def by its lexical owner,
using the registry's spelling: module and class nesting, `::` paths, and
`.singleton` for `def self.` and `class << self`. A def inside a block or a
method body has no lexical owner and is left alone. So is a key that matches
twice in one file.

In `closed_build.bash` phase 1 the manifests are empty, so that phase's presym
list comes from the full mrblib. Phase 2 writes the real manifests. The stubbed
copies and each gem's `gem_init.c` are then regenerated, and the presym list is
scanned again.

## When a stub runs anyway

A stubbed body raises `ScriptError`, which `rescue => e` (a `StandardError`
rescue) does not catch, so a model gap fails loudly with the method in the
backtrace. A game trace (`scripts/bc2cpp/trace_host.bash`, see "Verify mode" in
[Unregistered compiled methods](bc2cpp-unregistered-methods.md)) reports it like
any other uncaught exception.

`scripts/bc2cpp/mrblib_stubs_check.rb` checks which entries are listed and the
rewrite.

## Core gems

`mruby-core-compiled` lists its own entries the same way, in
`core_compiled_stubs.txt`. The core gems and external gems whose mrblib it reads
(`BC2CPP_CORE_MRBLIB_GEMS`, `BC2CPP_EXTERNAL_MRBLIB_GEMS`) get the same copies:
`bc2cpp_stub_core_mrblib` (`build_config.rb`) sets each one's
`build_config_initializer`, which runs after the gem's rbfiles are globbed and
before its gem_init rule is defined. mruby's top-level `mrblib/*.rb` is built by
a rule in mruby's own `tasks/mrblib.rake`, not by a gem, so the entries defined
there keep their bytecode.

## Class bodies

With `BC2CPP_LOAD_COMPILE` (default `all`) the keys of the manifest are removed from the residual mrblib altogether
instead of being emptied, and the class bodies around them are compiled too:
[Class bodies as generated C++](bc2cpp-class-bodies.md).
