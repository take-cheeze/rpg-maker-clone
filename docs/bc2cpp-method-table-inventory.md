# Unified method-table inventory

The closed-build inventory combines the engine/RGSS retention report and the remaining core/runtime entries. The baseline audit at `3777da393` counted 1,252 installed entries and reconciled every one of the earlier report’s 446 owner/name pairs. Function addresses were resolved against the host binary to distinguish native implementations from generated C++ wrappers.

## First native-registration reduction

Candidate discovery now accepts any callable expression when the native registration’s owner and method name are fixed. A lambda or template specialization does not make the installed method key dynamic. The existing reachability proof still excludes aliases, Ruby overrides and computed-name owners, and retains names looked up inside callable bodies.

The proof reached a fixed point after two passes: the closed list grew from 3,564 to 3,584 keys, while the open list (1,143), core ROM exclusions (152) and core runtime removals (104) stayed unchanged. Runtime enumeration confirmed exactly these 20 additional removals:

- `RGSS::Color`: `red`, `green`, `blue`, `alpha`, and their setters (8).
- `RGSS::Tone`: `red`, `green`, `blue`, `gray`, and their setters (8).
- `RGSS::Rect`: `set`, `y`, `y=`, `height=` (4).

The installed table falls from **1,252 to 1,232 entries**. The count guard that once read `scripts/bc2cpp/method_table_threshold.txt` has been removed, so this count is no longer enforced. These are entry counts, not measurements of backing-table capacity or binary size.

## Native alias reduction

Native alias destinations now participate in the core runtime-removal proof.
The new name defines a table entry, while the source name remains a lookup.
Alias chains therefore retain their sources; computed owners, reachable names,
fragment-built names and keys shared with ROM entries stay protected.

Against the `e83fd22bb` baseline, the proof reached a fixed point after two passes. Core runtime
removals grew from 104 to 107; the other lists stayed unchanged. Runtime
enumeration confirmed exactly three removals: `Integer#modulo`, `Float#modulo`
and `Module#attr`. Their source methods (`%` and `attr_reader`) remain installed.
The table now contains **1,229 entries**, down from 1,232 after the first batch.
This measures entries, without claiming a reduction in allocated table capacity
or a generator speedup.

## Ruby alias operand reduction

The core scan now reads both `ALIAS` operands from the RITE binary instead of
retaining every symbol in a class body containing an alias. The source and
destination names still count, including operator names; unrelated definitions
do not become live just because they share that body. An unresolved source
operand retains every symbol conservatively.

The proof adds 23 core ROM exclusions and three runtime removals, with the open
and closed engine lists unchanged. The additional entries are:

| Owner | Removed names |
| --- | --- |
| Array | `__combination_init`, `__combination_next`, `__fill_exec`, `__fill_parse_arg`, `__product_generate`, `__product_next`, `flatten`, `flatten!` |
| String | `capitalize`, `capitalize!`, `casecmp`, `casecmp?`, `downcase`, `downcase!`, `partition` |
| IO | `readchar`, `sync`, `sync=`, `sysread` |
| File | `truncate` |
| Integer, Float | `truncate` on each |
| Exception | `exception` |
| Kernel | instance and singleton `sprintf` |
| StringIO | `rewind` |

The table falls from **1,229 to 1,203 entries**. The threshold records this new
count. These remain entry counts; allocated table capacity and generator speed
are not measured here.

## Unused compiled core Ruby reduction

The general receiver-blind proof now also considers Ruby-defined core methods,
including methods compiled to C++. A candidate must have a fixed, unambiguous
owner and no reachable name, fragment-built name or direct compiled call.
Explicit public sends still count as lookups. Keys shared with ROM entries
stay protected to avoid replacing a readonly entry with a RAM tombstone.

Runtime enumeration confirms exactly **75 compiled entries removed**, taking the
table from **1,203 to 1,128 entries**, with no additions. Core runtime removals
grow from 110 to 185; core ROM exclusions (175), open (1,143) and closed (3,584)
engine lists stay unchanged. The removed entries are:

| Owner | Removed names |
| --- | --- |
| Array | `__repeated_combination`, `bsearch`, `bsearch_index`, `combination`, `dig`, `fetch_values`, `fill`, `keep_if`, `permutation`, `product`, `repeated_combination`, `repeated_permutation`, `reverse_each`, `rfind`, `transpose` |
| Comparable | `between?` |
| Enumerable | `cycle`, `drop`, `drop_while`, `each_cons`, `each_entry`, `each_slice`, `grep`, `grep_v`, `group_by`, `max_by`, `min_by`, `minmax`, `minmax_by`, `one?`, `partition`, `reverse_each`, `take`, `take_while`, `tally` |
| Enumerator | `feed`, `peek`, `peek_values`, `rewind` |
| File singleton | `foreach` |
| Hash | `dig`, `fetch_values`, `flatten`, `invert`, `keep_if`, `transform_keys`, `transform_keys!`, `transform_values`, `transform_values!` |
| IO | `each_byte`, `printf`, `rewind` |
| Integer | `allbits?`, `anybits?`, `ceildiv`, `integer?`, `nobits?` |
| Numeric | `integer?`, `nonzero?` |
| Range | `overlap?` |
| String | `each_byte`, `gsub`, `gsub!` |
| StringIO | `fsync`, `read_nonblock`, `readchar`, `sync`, `sync=`, `sysread`, `write_nonblock` |
| Struct | `dig` |
| Symbol | `capitalize`, `casecmp`, `casecmp?`, `downcase` |

The closed build omits these registrations and load-time Ruby definitions.
Generated C++ implementations can remain until the linker discards unused
sections. Other builds retain the registrations. These are entry-count
measurements; table capacity and generator speed are not measured here.

## Math diagnostic-label reduction

With the closed-world literal-lookup proof, names used only as labels in the
verified mruby-math `domain_error` helper no longer count as method lookups.
The helper signature and body must match the formatting-only implementation;
all references must be direct literal calls. Unknown bodies, macro shadowing,
scoped calls or escaping references keep the labels conservatively. Actual
lookups elsewhere still retain a name, and the helper's runtime code is unchanged.

This removes 17 native entries: instance and singleton `acos`, `acosh`, `asin`,
`atanh`, `log10`, `log1p`, `log2` and `sqrt` on Math, plus `Integer.sqrt`.
Core runtime removals grow from 185 to 202; core ROM exclusions (175), open
(1,143) and closed (3,584) engine lists stay unchanged. The table falls from
**1,128 to 1,111 entries**.

## Unused dependency reduction

RPG2k-only targets omit Marshal, Struct, Random and Kernel extensions. Full
multi-format builds retain them; see [dependency selection](rpg2k-dependencies.md).
Their absence removes 34 entries and lets the reachability proof eliminate six
more: `Kernel#instance_variables`, four engine `random` accessors and
`Game::Troop#members`. Runtime enumeration confirms 40 removals and no additions,
taking the table from **1,111 to 1,071 entries**.

## Combined inventory after all six reductions

| Category | Native | Compiled C++ | Undefined | Total |
| --- | ---: | ---: | ---: | ---: |
| Collections, strings and enumeration | 156 | 106 | 0 | 262 |
| RGSS | 113 | 51 | 0 | 164 |
| Game | 0 | 144 | 0 | 144 |
| Numeric, math and random | 68 | 13 | 2 | 83 |
| IO, files and StringIO | 75 | 23 | 0 | 98 |
| Object model and top-level protocols | 86 | 4 | 1 | 91 |
| RPG2k | 2 | 93 | 0 | 95 |
| LCF | 6 | 30 | 0 | 36 |
| Symbols, booleans and nil | 26 | 2 | 4 | 32 |
| Time | 22 | 0 | 0 | 22 |
| Fiber, Proc and GC | 16 | 0 | 0 | 16 |
| RPG2k3 | 0 | 15 | 0 | 15 |
| Exceptions | 11 | 2 | 0 | 13 |
| **All entries** | **581** | **483** | **7** | **1,071** |

No method-table entry points to Ruby bytecode. This does not count standalone blocks or startup bytecode. The seven undefined markers preserve method undefinitions: singleton `new` on Integer, Float, Symbol, TrueClass, FalseClass and NilClass, plus `Class#module_function`.

## Rechecking

`scripts/bc2cpp-rpg/static_dispatch_scan_check.rb` covers lambda/template/function-expression candidates, callable-body lookups, alias exclusions, computed names/owners, Ruby overrides and existing candidates. `scripts/bc2cpp/unregistered_verify_check.rb` exercises ordinary removal, preserved `respond_to?` answers and aborting verify stubs even when no named callable is available.

`scripts/bc2cpp/core_native_candidates_check.rb` also checks native alias
destinations, chains, source lookups, computed owners and ROM-sharing exclusions.
The runtime verify fixture removes a native alias, confirms its source still
answers, and deliberately calls the removed alias to check the aborting trap.
The same core candidate check covers decoded Ruby alias sources (including an
operator), unrelated definitions beside an alias, source-body liveness and the
conservative unresolved-operand fallback.
It also checks unused public and singleton core definitions, direct compiled
calls, public sends, Symbol lookups, fragments, ROM sharing and ambiguous
owners. `scripts/bc2cpp/static_dispatch_lists_check.rb` checks that core removals
apply only to closed builds.
Diagnostic-label checks verify the literal-lookup gate, the helper body, actual
Ruby/native/generated lookups, both module-function registrations, path scope,
macro shadowing and escaping or scoped references.

Build with `scripts/bc2cpp/closed_build.bash BUILD_DIR`, then run `scripts/bc2cpp/host_sweep.bash BUILD_DIR GAME_DIR`. Repeat with `BC2CPP_UNREGISTERED_VERIFY=1` and `METHOD_TABLE=skip`: the verify build registers traps under removed names, so its table count is intentionally different. The plain host count is available through `BC2CPP_HOST_MT_COUNT=1 BUILD_DIR/trace-host/trace_host GAME_DIR 1`.

The first reduction passed the New Game, battle, menu, save/load and 543-map
sweeps in both plain and verify builds. A deliberately forced lookup of removed
`RGSS::Color#red` aborted with the expected `UNREGISTERED_VERIFY` message,
confirming that the verify traps were active.

The alias reduction passed the same scenarios and 543-map sweeps in plain and
verify builds. Deliberate calls of each of the three removed aliases aborted
with its expected `UNREGISTERED_VERIFY` diagnostic. Independent count-only and
per-entry dumps both reported 1,229 entries; the dumps also confirmed that all
three alias sources remain installed.

The Ruby alias operand reduction was rechecked on `a62699052`. Plain and verify
builds passed the same scenarios and all 543 maps. Runtime enumeration found
exactly the 26 listed removals and no additions; the plain sweep confirmed
1,203 entries at the new threshold. Deliberately calling each removed entry
under verify mode aborted with its expected method name.

The unused compiled-core reduction was checked on `94de5d14e`. Plain and verify
builds passed the same scenarios and all 543 maps. Runtime enumeration found
exactly the 75 listed compiled entries removed and no additions; the plain
sweep confirmed 1,128 entries at the new threshold. Forced lookups of all 75
removed entries aborted with their expected method names under verify mode.

The Math diagnostic-label reduction was checked on `ec25ff829`. Plain and verify
builds passed the same scenarios and all 543 maps. Enumeration found exactly
the 17 listed native entries removed, with no additions, and the plain sweep
confirmed 1,111 entries. All 17 forced lookups hit the expected verify traps.
Both builds retained `Math.sin(0) == 0` and the exact `Math::DomainError` message
from `Math.log(-1)`.

The unused-dependency reduction passed New Game, battle, menu, save/load and all
543 maps in fresh plain and verify builds. Both confirmed the omitted constants
and Kernel factories are absent. Color, Tone, Rect and Table byte callbacks
round-trip without Marshal in both builds; `instance_variable_get` remains
available for the RGSS probe. The plain table contains 581 native entries,
483 compiled entries and seven undefined markers.

## Temporary support driver entries

Against the native-only baseline at `21e93f701`, capturing iterator driver Procs and then
removing their temporary names reduces the installed table from **1,102 to 1,061 entries**.
The exact removal set is 40 `__bc2cpp_*_driver` methods and `Bc2cppResumable#drive`, with
no additional entries installed. The resulting inventory has 562 native C callables,
491 generated C++ callables, one native continuation (`Kernel#p`) and seven undefined markers.
The omission proof is unchanged: 1,154 open keys (included in 3,584 closed keys), 186
core ROM exclusions and 200 core runtime removals.

The iterator saved-body array and the resumable module's hidden Proc slot retain these
implementations across GC. Re-registration reuses the saved iterator Procs, and resumable
calls read their saved Proc instead of looking up `drive`. See
[the driver lifetime rule](bc2cpp-enum-step.md) and `scripts/bc2cpp/native_fiber_check.rb`.
The method-table threshold records 1,061; these are entry counts, not backing-table capacity
or binary-size measurements.

New Game, battle, menu, three save scenarios, Continue and all 543 maps pass in both plain
and registration-verify builds. The native Fiber check also confirms absence of temporary
driver names, saved-Proc identity after re-registration, and behavior across full GC and suspension.

## Pool string values

A bytecode pool string's generated value (`bc2cpp_pool_str`, not a folded
constant's `mrb_str_new_cstr`) no longer counts as a generated-code literal when
the pool verdict proves its uses pure. Such a value is the same string the pool
analysis already checked, so the name stays out of the table. The closed-list proof
grows from 3,633 to 3,639 safe keys, the dynamic-names report keeps 403 entries
instead of 409, and the closed host's table falls from **1,061 to 992 entries**.

The plain closed build and host sweep pass (New Game, battle, menu, three save
scenarios, Continue and all 543 maps). The verify build repeats the sweep with
`BC2CPP_UNREGISTERED_VERIFY=1` and `METHOD_TABLE=skip`. Its traps must abort on
any lookup of a removed name.

## Message-macro names

A native macro that stringifies a parameter only into an error message (`#val " too big"`) no longer makes that parameter a method name, because a method name has no blank. On the closed host (HEAD `9e55bd1`, 941 entries before) this removes `RGSS::Rect#width=`, `RGSS::Window#width=` and `RPG2k::Window#width=`, leaving **938 entries**. The `width` getters and the `x` entries stay: other sources keep them. The plain and verify builds both pass New Game, battle, menu, three saves, Continue and all 543 maps; the verify build traps no lookup of the removed names.

## VM-free protocol names

The closed (VM-free) proof no longer treats mruby's implicit protocol names as dynamic: `ALWAYS_DYNAMIC` (`tools/bc2cpp/static_dispatch_registrations.rb`) is the open build's backstop only. A closed-build name stays kept when the proof reads a by-name send, a presym, a literal in generated code, or a bytecode send, which is what the scans already cover. Against the list without this change, the closed proof removes 10 more entries (the four `_dump`/`_load` pairs on `RGSS::Color`, `Rect`, `Table` and `Tone`, plus `Game::Party#unequip_to_bag` and `RGSS::ErrorReport.singleton#puts_text`), the core ROM exclusion adds six (`Hash#to_hash`, `Integer#to_int`, `String#to_str`, `Kernel#clone`, `Kernel#send`, `Module#class_eval`) and the core left-out list adds `Hash#each_pair`.

The closed host table is now **1,143 entries**. Measured against the Marshal-only variant of this change on the same base it is 1,150, and the proof lists predict 9 fewer entries, so 1,141 was expected; the 2-entry gap is not yet explained. The plain build and the UNREGISTERED_VERIFY build both pass New Game, battle, menu, three saves, Continue and all 543 maps.

## Non-lookup evidence

Names that only a non-lookup spelled no longer keep a compiled entry registered on the closed host:

- The Proc `arity` / `parameters` stand-in is matched in the shape `bc2cpp.rb` now emits, so its `mrb_proc_new` is no bytecode proc again (`PROC_SPEC_STAND_IN_CALL`; the fixture reads the emitter's own text).
- Core Ruby: a Symbol only given to `attr_*`, or as the name of a `to_enum` on a core `self`, looks nothing up on an engine object; an `alias` / `undef` counts its own operands, not every symbol of the class body (`Integer#step` kept `Game::Battle#step` and its callees).
- Native sources: `MRB_OPSYM(x)` is an operator and `MRB_IVSYM(x)` an `@ivar`, so a macro applying them to a parameter names no method; the format of `mrb_get_args`, the key of `OPERATOR_SYMBOL` and a `strcmp` operand are not interned; the desktop application (`src/`) is not linked into the closed binary.

Measured with the core exclusions below, on `3388613`: the proof lists were open 14, closed 3,473, core ROM 195 and core run-time 197 before, and are open 14, closed 3,738, core ROM 211 and core run-time 207 after. The closed host table is **852 entries**; its count on `3388613` before these two changes was not re-measured. The plain and verify host sweeps (the latter with `BC2CPP_UNREGISTERED_VERIFY=1 METHOD_TABLE=skip`) pass all 543 maps and the scripted scenarios.

## Core ROM exclusions beyond the name scan

The core scan stopped counting three spellings as lookups of an identifier: `MRB_OPSYM(div)` with cdump's operator rows, a literal handed straight to the verified formatters `mrb_int_overflow` and `mrb_sys_fail` (the latter only while nothing makes `SystemCallError`, because `mrb_sys_fail` passes the message to `SystemCallError._sys_fail` when that class exists), and the Symbol of `Array#index`/`#rindex`'s `to_enum` call while `CoreEnumeratorFree` holds. These come on top of the `ALWAYS_DYNAMIC` drop above. The entries each rule freed, measured on a closed build at `80dda2f` (before that drop):

| Rule | Core ROM | Core run-time |
| --- | --- | --- |
| `MRB_OPSYM`, cdump rows, `mrb_int_overflow` labels | `Float#div`, `Float#floor`, `Integer#div`, `Integer#floor`, `Integer#lcm`, `Integer#pow` | |
| `Array#index`/`#rindex` `to_enum` Symbol | `Array#rindex`, `String#rindex` | |
| `mrb_sys_fail` labels | `File#_atime`, `File#_ctime`, `File#_mtime`, `File#flock`, `IO#sysseek`, `IO#syswrite`, `Time#ctime` | `File#atime`, `File#ctime`, `File#mtime`, `File.pipe?`, `FileTest.pipe?`, `IO.pipe`, `IO._pipe`, `StringIO#syswrite` |

A second build with `BC2CPP_UNREGISTERED_VERIFY=1` passes the same sweep, so no scenario looked a removed name up; a removed name no scenario reaches (for example `File#flock`) is not exercised by it. `scripts/bc2cpp/core_kept_report.rb` prints why each core ROM key still kept stays.

## `super` reach and reflective-file names

A `super` in a class's method reaches that name only on the class's ancestors, so the closed proof bounds it to the ancestor chain (`SUPER_REACH`, nfcxx#836): the six `RPG2k3::Scene::Battle` overrides that call into `RPG2k::Scene::Battle` leave the table, **915 to 909 entries** on pin `70999605` (fork `15f679a`). A core Ruby file that sends a reflective name no longer counts the names only a variable, constant, class or definition operand holds (nfcxx#841): the closed list goes from 3,745 to 3,749 keys and the table to **905 entries** (`Game::Actors#all`, `RGSS::ErrorReport::Tee#flush`, `ShopQuantity#max`, `#max=`). The plain and `BC2CPP_UNREGISTERED_VERIFY=1 METHOD_TABLE=skip` host sweeps pass all 543 maps and the scripted scenarios.

The 293 compiled entries still kept, by first reason (`scripts/bc2cpp/dynamic_names_report.rb`): `initialize` and `initialize_copy` named by mruby-enumerator and core C (45), Symbol literals such as `:update` and `&:dead?` (33), core Ruby sends to a receiver that may be an engine object (32), by-name sites in generated rgss, rpg2k and lcf code (60), `lib.cxx` attr lookups on Font and friends (26), sends from `LCF::Array2D#[]=` and similar that may run as bytecode (17). Each needs receiver or type reasoning, not another scanner rule.

## Class-test reach

A send on a value a class test has just passed (`x.is_a?(C) && x.m`, `raise ... unless x.is_a?(C)`) looks `m` up on C, its ancestors and its subclasses only, so the closed proof records that owner set for `m` (the `SUPER_REACH` map, nfcxx#847) instead of making `m` dynamic. It applies to an argument nothing rewrites, when every path to the send takes the true edge of the branch on the test, in an irep with no handler, and only while `is_a?`, `kind_of?` and `raise` have no definition but the core natives. `LCF::Array2D#[]=`'s `entry.schema` and `entry.to_lcf` no longer keep `LCF::File`, `Database`, `MapTree`, `MapUnit` and `SaveData`'s `schema`, `File#to_lcf` and `Array2D#to_lcf`: the closed list goes from 3,749 to 3,756 keys and the closed host table from 905 to **898 entries** (pin `70999605`, fork `15f679a`). The plain host sweep and the `BC2CPP_UNREGISTERED_VERIFY=1 METHOD_TABLE=skip` verify sweep pass all 543 maps and the scripted scenarios.

286 compiled entries stay kept. From `LCF::Array2D#[]=` only `Array2D#same_schema?` remains, a send on `self`; narrowing a self-send to its class's relatives is a separate step.

## Singleton ROM tables

A native table under `X_singleton` that is installed into X's singleton is now a candidate for the core ROM exclusion list (nfcxx#850; `NativeRomOwners` spells that owner `X.singleton`, so it was never matched). A singleton table under a plain `X` token still shares that token and stays kept.

The core ROM exclusions go from 237 to 304 keys, all `X_singleton` (`Math` 23, `File` 17, `GC` 8, `FileTest` 5, `Time` 4, `IO` 2, `Kernel` 2, one each of `Array`, `Exception`, `Hash`, `Integer`, `Module` and `Symbol`), and the closed host table from 898 to **833 entries**. The plain build and the `BC2CPP_UNREGISTERED_VERIFY=1 METHOD_TABLE=skip` build both pass all 543 maps and the scripted scenarios.

## Engine ROM tables

The engine gems' ROM tables (`mruby-rgss`, `mruby-lcf`) name their class like a core table: `#define MRB_MT_CLASS RGSS__Window` before the table, `#undef` after it, with `__` for a namespace and a trailing `_singleton` for a class object's table. The closed proof lists an entry of such a table whose name nothing looks up (`engine_rom` in the static dispatch lists, a subset of `closed`), and `build_config.rb` leaves it out of the table at compile time. Nothing is removed at run time, so no RAM tombstone. A key counts only when the token-named entries and the installed rows agree on every function of that name; a table installed into another class, or an entry without a token, keeps it. Operator entries (`Color#==`, `Table#[]`) are not candidates.

Converting the engine natives to ROM tables (#3216) had put about 180 entries back that registrations left out before: the closed host table read **995 entries**. Leaving the proven-dead ones out takes it to **821** (182 keys in `engine_rom`); the ROM entry arrays shrink by 174 entries (16 bytes each) and `trace_host` text by 40 KB. The heap method tables are unchanged (41 entries, 224 layers, 10,576 bytes). The plain host sweep passes all 543 maps and the scripted scenarios.

The core ROM entries still kept (363) are operators (72), names the engine's Ruby, a native or the generated code spells (242) and names a live core body or a direct call keeps (49); none is held by a shared table any more.

## Initializer sites

An `initialize` leaves the table when every construction site of its class calls the compiled `_impl` directly (the initializer proof, `InitializerTables`). Each emitted copy of a `new` site (and of an initialize's `super`) is now marked, and a site is direct when every copy is: a block's copies belong to the method that encloses it, a guarded construct whose else arm is a `NEW_IDENTITY` violation never dispatches, a call without keywords to a keyword-declaring initializer is the keyword construct with every keyword omitted, and a class another gem emits is built through its exported `_impl` (nfcxx#905). `scripts/bc2cpp/initializer_sites_check.rb` holds the shapes.

The closed host table goes from 821 to **799 entries**, the compiled entries kept from 243 to 221, the `initialize` entries from 45 to 23 and `bc2cpp_owner_call` from 2,239 to 2,198. The plain and `BC2CPP_UNREGISTERED_VERIFY=1 METHOD_TABLE=skip` host sweeps pass all 543 maps and the scripted scenarios.

The 23 left: the native `initialize` and `initialize_copy` of `RGSS::Bitmap` (and `Bitmap::LoadError`), `Color`, `Font`, `Plane`, `Rect`, `Sprite`, `Table`, `Tilemap`, `Tone`, `Viewport` and `Window` (17; `mrb_obj_new` and `mrb_obj_dup` in core C look them up), `RPG2k` (the host entry header constructs it with `mrb_obj_new`), and five classes built through `klass.new` on a class held in a variable (`LCF::SaveTyped::Record#table` and `#rows`: `Game::Screen`, `Game::MoveRoute`, `Game::Picture`, `RPG2k::Scene::Title` and `SaveTyped::Record`), whose receiver is one of several classes of another gem.

A `klass.new` whose receiver is a parameter every caller fills with class constants constructs each class directly (one exact-class arm, a violation for any other receiver), and those constants resolve lexically, so `Picture` inside `LCF::SaveTyped` no longer reaches `Game::Picture` (nfcxx#915). `Game::Screen`, `Game::MoveRoute`, `Game::Picture`, `RPG2k::Scene::Title` and `LCF::SaveTyped::Record` leave the table: the closed host table goes from 763 to **758 entries**, and 18 `initialize` entries remain (the native RGSS ones and `RPG2k`). The plain host sweep passes all 543 maps and the scripted scenarios. `scripts/bc2cpp/class_object_new_check.rb` holds the shapes.

An `initialize` or `initialize_copy` that only a construction looks up is kept as a constructor row (`MRB_MT_CTOR_ROW`, take-cheeze/mruby#16; nfcxx `CTOR_ROWS`): method lookup, `respond_to?` and the method list do not see it, and `mrb_obj_new`, `Class#new`, `dup` and `clone` still run it. The proof's conditions: no Symbol literal or bytecode send of the name, no `super` that may reach the owner, no native lookup of the name on a superclass of the owner, and no generated owner call listing the owner (the direct constructions call `mrb_obj_init` instead). A native ROM entry becomes a row through the exclusion header (`2`), a compiled one in its generated table. The closed host table goes from 758 to **741 entries**: the engine `initialize` entries go from 18 to 2 and its `initialize_copy` entries from 5 to 0. Left: `RGSS::Rect#initialize` (registered with `mrb_define_method`, outside the ROM table) and `RGSS::Tilemap#initialize` (its ROM entry and the wio build's registration disagree, so it is no engine ROM key). The core classes' own `initialize` entries are not candidates yet. `scripts/bc2cpp/ctor_rows_check.rb` holds the rule.

## Settled core aliases

A core class-body `alias new old` or `alias_method :new, :old` whose source is the owner's one core Ruby definition is registered under `new` from that definition (CORE_ALIASES), so the receiver-blind core scan no longer counts its source as a lookup (nfcxx `SETTLED_ALIASES`). The closed host table goes from 741 to **727 entries** (`Enumerable#inject`, `#entries`, `Integer#next`, `String#next`, `#next!`, `#codepoints`, `#__codepoints`, `Hash#merge!`, `Array#entries`, `Range#entries`, `Enumerator#next`, `#next_values`, `StringIO#eof`, `#tty?`). The plain and `BC2CPP_UNREGISTERED_VERIFY=1 METHOD_TABLE=skip` host sweeps pass all 543 maps and the scripted scenarios. `scripts/bc2cpp/core_kept_report.rb --runtime` prints why each core run-time registration still kept stays.
