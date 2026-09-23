# 0210. bc2cpp closed-world mode replaces proven-dead dispatch fallbacks

Date: 2026-09-23

## Status

Accepted

## Context

Each guarded call site in bc2cpp output ends with a by-name fallback: a class
guard chain, then `bc2cpp_send(M, recv, i, argc, ...)` in the `else` arm (ADR
0209). The fallback exists because the receiver may be a class the chain does
not list: nil, a subclass, an LCF object answering through `method_missing`, a
core class, or native RGSS. The RPG2k compiled gem has about 19,700 of these
sites.

The flash-limited builds (build_config.rb's `single_format_only`: psp, wio and
maix) drop mruby-rpgxp/rpgvx/wolf/mvjs, and RPG2000/2003 games carry no Ruby,
so the only Ruby those builds can ever run is the closed world the generator
already reads, plus the core and native sources of the build's own gems. On
those builds some fallbacks can be shown never to find a method. Behaviour must
not change: `NoMethodError` is still raised and rescued as the runtime expects
(`x.field rescue nil`, 149 `rescue StandardError` wrappers), so the site cannot
abort.

Until now the compiled gems never learned their build's gem list:
`NATIVE_SRCS`/`FOREIGN_RUBY_SRCS` are fixed globs in compiled_gems.rb.

## Decision

`BC2CPP_CLOSED_WORLD=1` is a generator switch. build_config.rb turns it on for
the three compiled gems on `single_format_only` builds (`conf.gem ... {
enable_bc2cpp_closed_world }`). Each compiled gem's codegen task then reads
`spec.build.gems`. It reads the list in the task, not in the gem block,
because dependency gems join the build after the gem block runs. The task
passes the list to bc2cpp as `BC2CPP_BUILD_NAME`/`BC2CPP_BUILD_GEMS`. The rake
task and bc2cpp.rb both run `bc2cpp_closed_world_violations` and fail the
build if:

- the build is not psp, wio or maix;
- the list lacks the closed-world gems;
- the list contains mruby-rpgxp, rpgvx, wolf, mvjs, eval, binding,
  proc-binding or the mirb/mruby/debugger binaries;
- the list contains mruby-compiler (maix) and a host source for that target
  compiles a Ruby string that is not a constant literal defining nothing.
  maix only evaluates the literal `"maix-ruby-alive"`.

In that mode, `ClosedWorld` (tools/bc2cpp/closed_world.rb) scans the build's
real outside sources. These are mruby core, every other gem's `src`/`core` and
`mrblib`, the closed-world gems' native `src`, `include/` and the target's host
sources. A guard chain's `else` arm becomes
`bc2cpp_nomethod(M, recv, i[, argc, args...])` only when all of these hold:

- no name-installing call is unresolved: alias, define_method or undef
  (`symbol_installed_names`); attr_* or define_singleton_method outside a
  class body; a `def` the registry did not attribute; Struct members;
  `Class.new`. None of them installs this name.
- no outside source defines the name. Native definitions are read from every
  `mrb_define_*` call and ROM table. If any file other than mruby core
  defines by a computed name, every site keeps its dispatch. Core's computed
  definitions only run for the Ruby-level calls above.
- every closed-world definer is a class declared by a `CLASS` opcode. It is
  not a module or singleton. It is never rebound. No outside file that defines
  classes spells both its root and its last path segment. Every descendant
  meets the same test. A superclass is matched by its simple name, and a class
  with an unresolved superclass counts as a descendant of every class.
- the chain lists every definer and every descendant. A POLY_SMALL_N chain
  counts the subclasses its INHERITED_GUARD (ADR 0207) adds to a branch; a
  subclass that guard leaves out (one with a mixin on the way) keeps the
  dispatch.
- the receiver cannot be a `method_missing` instance. Either no class has
  `method_missing`, or the receiver is the compiled method's own `self` and
  neither its owner nor any descendant has one. `method_missing` or
  `respond_to_missing?` on BasicObject/Object/Kernel, or outside the closed
  world, makes every site keep its dispatch.

`bc2cpp_nomethod` is one shared, out-of-line helper that ends in a cold
`[[noreturn]]` body. It calls `mrb_funcall_argv` itself, so the raise is
mruby's own dispatch. The class, message, `name`, `args`, call-depth check and
backtrace are the ones `bc2cpp_send` produced. The call site still sees a
function that returns. A known-noreturn call made the RPG2k gem 9.6 KB
*larger* at `-Os`, because GCC moves each such call to the end of its
function.

The same proof also removes guards. When a MONO_EMBED_GUARD site's receiver is
the compiled method's own `self`, the target's owner is that method's owner,
and the closed world proves the owner has no subclass (`exact_class?`), the
class guard can only be true. The site becomes a plain direct call
(`CLOSED_WORLD_SELF`). This is LEXICAL_SELF's reasoning applied to a MONO
target: the existing generator already trusts that `self` inside an owner's
compiled method is kind_of that owner.

In the same mode the guards' owner-class lookup uses `mrb_const_defined_at`,
so a guard never matches a same-named class found through ancestry. Without
the switch the output is byte-identical.

## Consequences

wio, measured by generating all three gems both ways and compiling each
`register.cxx` at `-Os` (x86-64 host g++, the build's own flags):

| gem | guard + fallback dropped | `bc2cpp_nomethod` | kept | `-Os` text before | after |
| --- | ---: | ---: | ---: | ---: | ---: |
| rpg2k | 1,724 | 17 | 4,948 | 4,711,325 | 4,604,072 (-2.3%) |
| rgss | 0 | 0 | 58 | 186,684 | 186,684 |
| lcf | 0 | 0 | 19 | 61,992 | 61,992 |

The RPG2k gem's `bc2cpp_send` sites fall from 19,664 to 17,923. Converting
sites to `bc2cpp_nomethod` alone saves little. Before the guard drop existed,
1,735 converted sites saved 2.1 KB. Nearly all of the gain comes from the
guards the proof removes.

Why rpg2k keeps the rest:

| reason | sites |
| --- | ---: |
| `method_missing_receiver` | 1,919 |
| `core_or_native` | 1,044 |
| `unknown_definer` (Struct members, attr_*/def outside class bodies) | 998 |
| `unlisted_class` | 507 |
| `opaque_definer` | 300 |
| `singleton_definer` | 139 |
| `dynamic_install` | 41 |

A further 2,126 guarded sites keep the dispatch without being modeled: the
untyped `x[i]` tails and the GETIDX/SETIDX typed fallbacks. All of them send
`[]`/`[]=`, which core defines.

The generator prints each refused site's reason (`/* CLOSED_WORLD kept:
<reason> */`) and a per-reason summary on stderr. The largest reason is
`method_missing_receiver`: LCF::Array1D/Sections/File and
RGSS::ErrorReport::Tee define `method_missing`, so only `self` receivers
convert. When the LCF `method_missing` removal lands, the analysis picks that
up with no code change. Tee's forwarding `method_missing` still blocks every
non-self receiver after that; replacing it with explicit IO delegation is the
follow-up that frees those sites.

One premise carries over from the existing generator. An unguarded MONO
direct call assumes its receiver is the owner's instance, just as it already
assumes a method and not `method_missing` answers it. LEXICAL_SELF relies on
that assumption already; the `self` rule and CLOSED_WORLD_SELF rely on it too. `scripts/bc2cpp_closed_world_check.rb` covers the
build check and the generated code. It also compiles fixtures against the real
mruby core and checks the raised `NoMethodError` against the interpreter's.
