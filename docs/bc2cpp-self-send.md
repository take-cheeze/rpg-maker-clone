# Self-sends in bc2cpp: what stays out of a direct call

A self-send is a send whose receiver is `self`: `foo(x)` and `self.foo(x)` in a method, a block or a class body. This
page measures which self-sends in the closed world's engine Ruby do not become a direct compiled call, why bc2cpp
gives for each, and what bytecode IR would need to settle the rest. The numbers are from a census on `master` 78ecd7b;
the design sections are not run.

## How the numbers were produced

```sh
MRBC=build-closed-bc2cpp/host/mrbc/bin/mrbc ruby scripts/bc2cpp/self_send_census.rb [--all] [--tsv FILE]
```

`scripts/bc2cpp/self_send_census.rb` runs one bc2cpp pass over the closed world's mrblib (the same sources and
environment as `coverage_report.rb`, without `SKIP_UNSUPPORTED`, so a refused body stays visible). A prepended hook on
`CodeGen` records the text `compile_send` returned for each self-receiver send and the `#error` of each compiled
method. The hook is loaded with `ruby -r` into the child only. Its C++ output is byte-identical to the shipped pass
(`cmp` of 472,383 lines), so the hook changes nothing measured. The parent then lists every send instruction of the
same bytecode (`BytecodeIR`), finds the self-receiver ones, and joins each to the hook's record by irep label and
instruction address. A send with no record is counted as `not_recorded`, not guessed.

What was not run: no C++ of the output was compiled, no closed build was made, no program was run. A closed build
takes 30+ minutes and was not needed for these counts.

A self-receiver `SEND` is one whose receiver register only ever holds a `LOADSELF` value
(`BytecodeIR.reaching_definitions`, the same test as `CodeGen#receiver_loaded_self?`).

## Outcome of a site

The outcome is read from the C++ text compile_send returns for that site:

| outcome | text | what runs |
| --- | --- | --- |
| `direct` | a call to a compiled `_impl`, or an inline arm, with no by-name call | the compiled body |
| `owner_table` | `bc2cpp_owner_call` | a method-table lookup by name id, restricted to a listed owner set, then the method's entry (`mrb_funcall_with_method`) |
| `by_name` | `mrb_funcall*`, `bc2cpp_send*` | a by-name dispatch |
| `guarded` | a direct call and a by-name else arm | the direct call on the fast path |
| `refused` | `#error` | the method stays bytecode |

`owner_table` is not a VM call: `bc2cpp_owner_call` runs `mrb_method_search_vm` and calls the found entry. It is still
a by-name lookup on every call, with a per-site cache (`BC2CPP_OWNER_ICACHE`, on by default), so it is listed as its
own outcome.

## Results: engine gems (`mruby-rpg2k`, `mruby-lcf`, `mruby-rgss` mrblib)

Self-receiver sends in the engine's compiled Ruby: **5,187** (5,173 `SSEND` family, 14 explicit `self.x`). Across all
closed-world methods (engine and core), 3,152 compile and none carries `#error`, so no method is refused.

| category | count | share | example (Ruby source) | reason bc2cpp gives |
| --- | ---: | ---: | --- | --- |
| `direct`: MONO 2,291, CLOSED_WORLD_SELF 1,625, LEXICAL_SELF 584, KERNEL_DIRECT 52, LEXICAL_SELF_IVAR_ACCESSOR 46, others 37 | 4,635 | 89.4% | | the proof names one definition |
| `owner_table`: `read` on the `LCF::SaveTyped` records | 243 | 4.7% | `mruby-lcf/mrblib/save_typed.rb:74` (`read`) | `POLY_DIAG path=chain receiver=runtime_class`; CHA_SELF plan `unsafe_name` (`inherited_lookup_safe?`: `read` has native definers in IO, StringIO and RGSS::HashArchive) |
| `owner_table`: `OUTSIDE_OWNER_CALL` (C-defined targets) | 30 | 0.6% | `mruby-lcf/mrblib/lcf.rb:4` (`ungetc`); also `exit`, `raise`, `dup`, `utf8_to_cp932`, `_init_file`, `_bgm_play_mem` | a bare send whose every answering class is a closed-world native owner; no direct arm |
| `owner_table`: `ARRAY_PUSH` | 4 | 0.1% | `mruby-rgss/mrblib/error_report.rb:146` (`push`) | an Array push arm is named, but the direct arm is not taken; why not analysed |
| `owner_table`: other `chain` (`alive?`, `step`, `path`) | 5 | 0.1% | `mruby-rpg2k/mrblib/game/battle.rb:672` | `POLY_DIAG path=chain receiver=runtime_class` |
| `owner_table`: a single definition that is an alias | 4 | 0.1% | `mruby-rgss/mrblib/lib.rb:1110` (`_rgss1_initialize`), `array_sort.rb:48` (`_rgss_native_sort!`) | `dynamic_single_registered_definition`, receiver implicit self |
| `owner_table`: several candidates, no complete set | 5 | 0.1% | `mruby-rgss/mrblib/lib.rb:559` (`asset_archive`), `lib.rb:1405` (`encryption_key`), `lib.rb:1668` (`wait`) | `dynamic_no_complete_candidate_set` |
| `owner_table`: `MONO` with an owner call, `none` | 2 | <0.1% | `mruby-rpg2k/mrblib/game/battle.rb:3239` (`deal_attack`), `mruby-rgss/mrblib/array_include.rb:32` (`length`) | not analysed |
| `class_body`: `attr_*`, `private`/`public`, `include`, `alias_method` in class and module bodies | 223 | 4.3% | `mruby-rpg2k/mrblib/game.rb` (94 of them) | class-body load program (statement compiled, not a method call) |
| `not_recorded`: literal-block self-sends (`x { }`) | 36 | 0.7% | `mruby-rpg2k/mrblib/scene/map.rb:1898` (`page_field`, 15), `scene/battle.rb:931` (`cached_bitmap`, 8), `lcf.rb:64` (`loop`, 7) | `compile_send` not called; block fallback, loop inline. Three sampled targets are direct `_impl(M, self, ..., blk)` calls in the output; the rest not checked |
| `by_name` / `guarded` / `refused` | 0 | 0% | | |

The direct row is 4,635; the other rows sum to 552 (`owner_table` 293, `class_body` 223, `not_recorded` 36).
By-name dispatch from a self-send: none. The only `mrb_funcall*(M, self,` line in the whole output is inside a
runtime helper (the super dispatch helper near line 598 of `shipped.cxx`), not a send site; `bc2cpp_owner_call*(M, self,`
has 409 text lines.

The earlier figure of about 156 self-sends inside compiled units did not reproduce under any reading tried here: by-name
self-sends are 0, owner-table sites are 293, and 50 of those are outside the `read` category.

Core mruby mrblib (`--all`) adds 424 `SSEND`-family instructions in core methods and 28 in core blocks (from the IR
enumeration; not broken down here).

## What still runs bytecode

- **Method bodies.** No engine method is refused, so a self-send in a method body never starts a VM frame for its own
  dispatch. The VM runs only if the resolved target is itself bytecode. The 17 core methods left interpreted (`Enumerable#chunk`,
  `Enumerator#each`, `Kernel#to_enum`, ...) are the candidates. None of the 1,807 distinct engine self-send names is one of
  them (a name check; the owner check was not run).
- **Class bodies.** Their statements go through the load program, which calls the class methods by name at load time (once),
  not per call. The four statements that keep bytecode (`DATABASE`, `MAP_UNIT`, `SYSTEM_SFX_SAVE_FIELD`, `EXT_SPELLINGS`)
  are constant assignments; a self-send inside one of their lambdas is a block send and is counted under blocks, not
  class bodies (`docs/bc2cpp-class-bodies.md`).

## Design: which categories bytecode IR can settle (not run)

The product owner's rule is that a self-send handled from bytecode IR needs no VM execution. On the measured numbers
that already holds for every engine self-send: the non-direct rows are owner-table lookups of compiled or native entries,
class-body statements at load, or literal-block sends. What remains is by-name cost on 293 sites, not VM execution.

To make the 293 direct, the IR side needs one fact per site: for the receiver's exact class, the name resolves to a
known definition before any other definer on its ancestor chain. Per category:

1. **`read` on `LCF::SaveTyped` records (243).** The receiver's class is exact (its ancestors are the `SaveTyped` chain).
   The blocker is `inherited_lookup_safe?` (`tools/bc2cpp/closed_world.rb`), which is name-level: `@outside_names`
   collects every name a native or outside Ruby source defines, with no owner (`native_file_facts` returns `names`
   per file). `exact_chain_lookup_safe?` is the chain-aware version, but it only accepts RGSS natives (`NativeDirect`
   registered owners, `native_only_in?('/mruby-rgss/src/')`). A fix needs owners for the C-defined `read` (mruby-io,
   mruby-stringio, RGSS::HashArchive) and a rule: no C definer on the chain before the Ruby definition, plus the CHA
   check for subclasses (`cha_self_plan`). This is the one large category; it changes the proof, so it needs fixtures
   and a closed build.
2. **C-defined targets (34: `OUTSIDE_OWNER_CALL`, `ARRAY_PUSH`).** The owner call is chosen because the answering owner
   is native. A direct C call would need the native arm proved for the self's exact class (`NATIVE_EXACT_DIRECT` for
   `self`). Why that arm is not taken for these names was not analysed.
3. **Alias-defined targets (4).** `_rgss1_initialize` and `_rgss_native_sort!` are one registry definition each, created
   by `alias_method`. The direct path refuses them as `dynamic_single_registered_definition`. Not analysed.
4. **Incomplete candidate sets (5).** `asset_archive`, `encryption_key`, `wait`, `asset_archive=`: several definers, no
   complete set for the receiver. Would need CHA_SELF on the module or singleton owner. Not analysed.
5. **Class-body self-sends (223).** Already IR-driven (load program). Making them direct would change installation
   (`mrb_define_method` at load), not a per-call VM question. No change proposed.
6. **Literal-block self-sends (36).** Probably direct already (three sampled). Check the rest before counting them.

## What blocks the rest

- Name-level outside definers: `inherited_lookup_safe?` and `exact_chain_lookup_safe?` cannot tell a C `read` on
  `IO` from one on the receiver's chain. This blocks category 1.
- Owner data for native names is not recorded; only the names are.
- The alias and candidate-set refusals (categories 3 and 4) were not traced to a line in the codegen.

## Recommendation

1. The engine already meets the stated rule: no compiled engine self-send runs VM bytecode for its own dispatch. Stop
   framing self-sends as a VM problem.
2. If by-name cost matters, category 1 (`read` on `LCF::SaveTyped`, 243 sites) is the lever. It needs an owner-aware
   native-name scan and a chain rule in `closed_world.rb` and `cha_self_plan`. It is not small and not clearly safe, so
   it was not prototyped here.
3. Keep `scripts/bc2cpp/self_send_census.rb` as the regression measure: the counts above should move only when the
   codegen changes.

## Not done or not verified

- No prototype. No category was small and clearly safe to change without a closed build and fixtures.
- No C++ compiled, no closed build, no program run.
- The "owner is interpreted" check is by name, not by owner.
- Literal-block sends: 3 of 36 sampled. "none" and `MONO`-with-owner-call (3 sites) not analysed.
- `scripts/bc2cpp/coverage_report.rb` exits 1 on this master at its summary step (a missing
  "integer-valued constants proven" heading); its shipped pass still completes. Not changed here.
