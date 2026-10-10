# 0313. bc2cpp: initialize arguments are pooled over every constructor site (CONSTRUCTOR_POOLS)

Date: 2026-10-02

## Status

Accepted. The keyword rows of the table below are superseded by [ADR 0382](0382-bc2cpp-ivar-typing-census-constructor-keywords-and-self-class.md):
a keyword parameter and a literal-keyword `new` / `super` call no longer withdraw the initialize (a post-mandatory parameter and
`**opts` still do).

## Context

ADR 0276 (numeric pools), 0296 (class pools) and the Fixnum entry proof pool the arguments of a method over every
call site, but `entry_arg_candidates` refuses `initialize` (rule 5): no `SEND` names it, so its sites cannot be
enumerated by name. Every ivar a constructor stores an argument into therefore stayed unpooled, and earlier
measurements blamed that for about 99 ivar-rooted rpg2k sites and for the 120 `Bitmap.new(w, h)` Integer-tag-else
sites (ADR 0307's follow-up), plus 58 "computed `new`" sites that were said to keep the analysis from seeing every
constructor call.

### Measurement (wio closed world, master `43031b24`, `scripts/bc2cpp_coverage_report.rb` + census, `3rd/*` populated)

The `new` sites. There are 675 sends named `new` in the three compiled gems and the core Ruby they link. The "58 computed"
were a misreading: `IrepScans#agreed_constant_name` returns nil inside a method with a `rescue` handler, so 57
`Bitmap.new "Title/#{name}"`-style sites looked non-constant, plus one `self.class.new` in `Hash#invert` (zero
arguments). Classified by what the receiver is:

| receiver | sites |
| --- | ---: |
| zero arguments (cannot enter any initialize that takes one) | 69 |
| a constant naming a class with a Ruby initialize | 301 |
| a constant naming a native or core class (`Rect`, `Color`, `Bitmap`, `Array`, ...) | 298 |
| `new` in a singleton method of X, or `self.class.new` in an instance method of X ("rooted": builds X or a descendant) | 7 |
| a receiver that is not provably a constant or rooted | 0 |

Every constructor call of the world is visible; the only unproven receivers were handler-covered constants and
`IO.open`/`StringIO.open`/`File.foreach` (`new(*args)` in a core singleton method, rooted at `IO`). `super` into an
initialize: 14 explicit `super(a)`, 1 bare `super` (an `ARGARY` + `SUPER` pair).

The ivar-rooted rpg2k sites by pool state (`BC2CPP_SEND_ROOT_REPORT`, ADR 0309's tool, 398 sites rooted at an `@ivar`):
100 pooled but consumed by name, 225 failed, 57 structurally poisoned, 8 attr_writer, 8 open. Of the 225 failed, 38
list only `initialize` arguments among their (first six) blockers, 114 list one among others.

The `Bitmap.new(w, h)` sites. Producers of `w`/`h` at the 115 sites that keep the Integer-tag else (ADR 0311's
`numeric_root_leaves`): constants whose numeric pool failed (`LINE_H`, `SCREEN_W`, `TILE`, `FACE_SIZE`: `flowfail`),
`Rect.new(...)`/`Bitmap.new(...)` natives' `.width`/`.height` results, `Array#max`/`size`, `Window#width`/`height`
readers. Constructor arguments reach only about a dozen of them (`SaveLoad#draw_slot_box` among them). The earlier
reading that constructor arguments block them does not hold.

## Decision

`tools/bc2cpp/codegen_constructor_pools.rb` adds the missing candidates to `entry_arg_candidates`, in the shape its own
candidates have, so the numeric, Fixnum and class pools read them unchanged.

The initialize D a class K runs is a fact of the closed hierarchy (`numeric_init_definition` up the superclass chain).
D is entered from:

* `Klass.new(args)`: every definition reaching the receiver register is a `GETCONST`/`GETMCNST` (reaching definitions
  through handler edges) and no `SETCONST` binds a value to that name (`ClosedWorld#class_valued_constant?`), so the
  site builds a declared class of that last-segment name (`classes_named`, a superset of the lexical lookup).
* a rooted `new`: the implicit-self `new` of `def self.m` in X and `self.class.new` in an instance method of X build X
  or a descendant. It reaches D when X is, or is above, a class that runs D (`constructor_chain`, with Object, Kernel
  and BasicObject appended).
* `super(a, b)` in the initialize of a subclass. A bare `super` forwards through `ARGARY`, which `NumericFlow` does not
  model, so it withdraws its target.

D is a candidate for positions `1..mand` (optional parameters' default code may read a later one) only when:

| condition | what withdraws | negative case in the check |
| --- | --- | --- |
| `BC2CPP_CONSTRUCTOR_POOLS=0`, no outside scan, no closed world, singleton makers, `new`/`allocate` lookup not standard | everything | kill switch, open world, singleton maker |
| a Symbol, alias or keyword naming `new`/`initialize` (`send(:new)`, `instance_method(:initialize)`, `allocate` + `send(:initialize)`) | everything | the three worlds |
| `alias_method :x, :initialize` / `alias x initialize` in a class body | that class's initialize | `CpAliased`; another class stays pooled |
| a Ruby `new`, a module or singleton `initialize`, an explicit `initialize` call, a `def` installed out of sight, a mixin into `Class`, a String `"new"`/`"initialize"` next to a computed-name send | everything | one world each |
| a `new` on a receiver that is neither constant nor rooted | every D it can get past ENTER for (`mand <= argc <= mand + opt`, any count with a rest parameter); everything when the count is a splat or keyword | computed receiver world (keeps the 4-argument constructor) |
| a splat or `**opts` at a site naming K (any keyword call until ADR 0382) | the D K runs | `CpSplat` |
| a constant bound by `SETCONST` | its `new` sites are unresolved (the line above) | `CpHandle = CpBound` |
| a wild (unresolved) superclass, an opaque class or descendant (`Class.new(K)`), a class outside a plain declared chain to Object (an Exception subclass is built by `raise`) | the D | wild, dynamic subclass, `CpErr` |
| a native or foreign Ruby source that spells both the root and the last segment of a class that runs D (`ClosedWorld#outside_spells_class?`; native comments are stripped, unlike `@outside_tokens`) | the D | the two build-gem worlds |
| post-mandatory parameters (keyword parameters too until ADR 0382) | the D (arity) | `CpPost` |
| a call with fewer than `mand` or more than `mand + opt` positionals | nothing: it raises in ENTER before the body | `CpOpt2` (the widest call keeps its own class) |

`method_missing` is not a withdrawal condition of its own: a proxy that forwards `new` does so with a `new(*args)` site,
which is a splat on an unknown receiver and withdraws everything (the proxy world in the check).

Kill switch `BC2CPP_CONSTRUCTOR_POOLS=0`: the shipped C++ is byte-identical to master (checked with `cmp` on
`shipped.cxx`).

`DynamicNames.analyze` is the old `universe` split into its two results so this analysis can ask whether any computed-name
send exists without counting the one aliased `:initialize` Symbol of `RGSS::Window` as a spelling.

## Consequences

Same tree, kill switch against default:

| | before | after | |
| --- | ---: | ---: | --- |
| `bc2cpp_send` call sites (census) | 2,815 | 2,814 | -1 |
| `RPG2k_*`/`Game_*` by-name-capable sends | 2,009 | 2,007 | -2 |
| callers of `bc2cpp_getidx` | 2,095 | 2,070 | -25 |
| callers of `bc2cpp_slow_*` / `bc2cpp_eqq` / `bc2cpp_nil_receiver` calls | 3,498 / 110 / 877 | same | 0 |
| `bc2cpp_nomethod` sites | 4,360 | 4,368 | +8 (dead fallbacks became errors) |
| class pools (ivar + argument) | 923 | 931 | +8 |
| `NOMETHOD_REVIEWED` keys | 2,926 | 2,920 | -6 (none added) |

All of it is removal: nothing moved into a helper or a nil arm (`nil_receiver`, `slow_*`, `eqq` counts are equal).
38 constructors are pooled (`CTOR` lines of the diagnostic); five argument pools and three ivar pools gained an exact class set (`Game::State` arg 1 and `@party`, `Game::Transition` args 3 and 4, `LCF::EventCommand` arg 4 and `@parameters`, `RPG2k::Scene::EventResolver` arg 1 and `@common`). The slice is small because what the constructors are given is mostly beyond the exact-class lattice
(`CTORARG` lines list the producers that dropped each argument): `self` (`Scene::Title.new(self)`), Symbol literals
(`SaveLoad` arg 3), another pooled ivar that itself failed, call results (`read_ber`, `partial`), and the parent
scene's several classes (`Scene::Base#@parent` joins 13 caller classes: a multi-class set no consumer takes).

Next levers, in the order the measurement suggests:

1. an exact `self` for a method of a class with no descendants (`entry[0]` of `NumericFlow` is OTHER today): three
   constructor arguments (`Title`, `MapWorld`, `VehicleWorld`) are `loadself`;
2. optional parameters: `RPG2k::Window#initialize(x = nil, y = nil, width = nil, height = nil)` and 10 more
   constructors have optional parameters; the default-prologue of `ENTER` has to be modelled first;
3. numeric constant pools that fail (`LINE_H`, `SCREEN_W`, `TILE`, `FACE_SIZE`), which dominate the `Bitmap.new(w, h)` sites;
4. `ARGARY` in `NumericFlow` (a bare `super`; 1 in an initialize here);
5. the name-keyed lookup merges same-named classes (`Game::Map` / `RPG2k::Scene::Map`, `Window`, `Battle`, `MoveCommand`),
   which costs `Game::Map#initialize` its pool; the lexical rule would need `cref` rather than the owner path.

Residual risk, as for ADR 0296: a pooled argument is an unchecked fact. A constructor call the scan cannot see (a native
that builds an instance of the receiver's class by `mrb_obj_class`, a `Class` subclass with its own `new` defined by
`mrb_define_method` on a helper function, hostile `Marshal.load`) turns it into a wrong answer instead of a logged
violation. Outside sources that spell the class name only are not seen. No firmware smoke (psp, wio, maix) or CI shard
was run; the 32-bit leg ran on a host build with `MRB_32BIT`/`MRB_INT32`, not on a target.

## Tests

`scripts/bc2cpp_constructor_pools_check.rb`: generated code for nine positives and eleven negatives, 16 withdrawal worlds,
kill switches and the open world; the fixture on real mruby, interpreted and compiled, on full-core, core-only and
32-bit `mrb_int` builds (nil, Hash and splat arguments included, zero dispatches on the proven methods).
`scripts/bc2cpp_constructor_pools_mutation_check.rb`: an unmutated control and 13 mutants of the soundness conditions,
each killed. New `constructor-pools` shard in `bc2cpp-checks`; the 32-bit run is in `bc2cpp-width (int32)`.
