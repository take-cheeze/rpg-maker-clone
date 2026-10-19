# 0473. bc2cpp: core method facts live in sig/native, not in generator constants

Date: 2026-10-16

## Status

Accepted

## Context

Several facts about mruby's core methods are already declared in RBS under `sig/native/` and read by small loaders
that reject any other shape: result classes (`core_results.rbs`, `NativeCoreResultSigs`), fresh-Array results
(`core_fresh_arrays.rbs`), block parameter shapes (`core_block_params.rbs`, `CoreBlockParamSigs`) and the core class
tree (`core_hierarchy.rbs`, `CoreHierarchySigs`). Many others were still Ruby constants spread over
`tools/bc2cpp/*.rb`, and some of them restated the class tree that `core_hierarchy.rbs` already holds
(`%w[Array Enumerable Object Kernel BasicObject]` in one file, `%w[Object Kernel BasicObject]` in another, the
mixin map a second time in escape_analysis.rb).

`grep -nE '^\s+[A-Z_]+ = (%w|%i|Set\[|\{|\[)' tools/bc2cpp/*.rb` lists 439 constants. Each was put in one of three
groups:

- (a) a fact about a core or native method or class: its result, owner, arity, what it reads or runs, or a class's
  ancestry;
- (b) an analysis-internal list: opcodes (`*_OPS`, `RETURNS`, `CALL_OPS`), operand schemas, report columns, caches;
- (c) a policy or limit: what an analysis refuses on (installer, rebinder and reflective send lists), which names an
  emitter has hand-written semantics for, family names and thresholds.

## Decision

The (a) constants that are plain facts are now read from `sig/native`, and their Ruby literals are gone. The
generator's output is unchanged: each derived value equals the old literal, in order where the order is read
(a scratch equivalence script compared every one against `git show origin/master`), and a closed-world generation of
mruby's core mrblib plus a fixture is byte-identical before and after.

New fact files, each read by `tools/bc2cpp/core_fact_sigs.rb` (`CoreFactSigs`), whose loader accepts one shape per
file and raises on anything else (owner not allowed, `module`/`class` keyword not matching `core_hierarchy.rbs`, a
superclass line, overloads, a block, a duplicate, the wrong parameter or return form):

| File | Declares | Replaces |
| --- | --- | --- |
| `core_frame_readers.rbs` | `Kernel#block_given?`, `#iterator?` (`-> bool`: reads the caller's block); `Kernel#binding` (`-> Binding`: captures the frame) | `CodeGen::BLOCK_GIVEN_NAMES`, `FRAME_READING_NAMES` |
| `core_enumerators.rbs` | `Kernel#to_enum`, `#enum_for` `-> Enumerator` | `CallSiteIndex::ENUM_SENDS`, `EnumeratorModel::NAMES` |
| `core_proc_calls.rbs` | `Proc#call`, `#yield`, `#[]`, `#===` as `(*untyped) -> untyped` | `CodeGen::PROC_CALL_NAMES` |
| `core_class_tests.rbs` | the owner and arity of each native class-test registration (`Kernel#is_a?` ... `NilClass#nil?`, `BasicObject#!`) | `CodeGen::CLASS_TEST_NATIVE_OWNERS` |

Derived from `core_hierarchy.rbs` through new `CoreHierarchySigs` helpers (`ancestors`, `superclasses_below`,
`subclasses`, `with_scan_spellings` for the native scan's "Nil"/"Basic_object" spellings):
`CallFacts::EVERYTHING`, `CLASS_OR_MODULE`; `CodeGen::NIL_OWNER_NAMES`, `FROZEN_TABLE_ANCESTORS`,
`BLOCK_ELEMENT_CHAINS`, `CLASS_TEST_CORE_CHAIN`, `CLASS_TEST_NUMERIC_FAMILY`, `CLASS_OBJECT_OWNERS`,
`NUMERIC_IVAR_UNIVERSAL_OWNERS`, `NUMERIC_SLOW_CMP_LOOKUP`, `ARRAY_NEW_CHAIN_OWNERS`; `ClosedWorld::GLOBAL_HOOK_OWNERS`;
`RbsRecordTypes::HASH_OWNERS`; `EscapeAnalysis::World::BUILTIN_INCLUDES`. Five of these (`CLASS_OR_MODULE`,
`CLASS_OBJECT_OWNERS`, `NUMERIC_IVAR_UNIVERSAL_OWNERS`, `GLOBAL_HOOK_OWNERS`, `HASH_OWNERS`) come out in a different
order than the old literal; every reader of them only tests membership.

The fact files are not program signatures. `RbsSignatures.files_in` skips `CoreFactSigs::FILES`: `Kernel#to_enum`,
`Proc#yield` and `Proc#===` have mrblib bodies, and a signature on one would attach an argument/return hint to it,
which is a behaviour change this move must not make.

`scripts/bc2cpp/core_facts_rbs_check.rb` (host, about a second) checks the facts against the 3rd/mruby sources the
build compiles. It runs twice in CI: in ruby-checks next to `native_results_check.rb`, which has no submodule and so
checks only the loaders (the source part prints SKIP), and in bc2cpp-build with `--require-mruby`, where a missing
tree is a failure:

- class tests: `NativeExpressionDevirt.scan_class_registrations` over `core_native_srcs` (the scan codegen itself
  uses) must find each name on exactly the declared owners, once per owner, with the declared required/optional
  argument counts (`MRB_ARGS_*`);
- frame readers: `block_given?`/`iterator?` are `mrb_f_block_given_p_m` on Kernel with no arguments; `binding` is a
  private Kernel native taking none (mruby-binding);
- enumerators: mruby-enumerator's `module Kernel` defines `to_enum` as `Enumerator.new self, meth, *args, **kwd`, and
  each other maker is an `alias` of it;
- Proc calls: each is `call_proc` in `mrb_init_proc` (src/proc.c) or a `def name(*args) call(*args) end` in
  mruby-proc-ext;
- `bc2cpp_cfunc_proc_call_p` in bc2cpp.rb spells exactly the Proc call names, so the runtime and the generator
  cannot drift;
- the loaders' rejections, `RbsSignatures` skipping the fact files, and the hierarchy helpers.

What stays in Ruby, and why:

- emitter coverage lists (`COLLECT_BLOCK_METHODS`, `ACCUM_BLOCK_METHODS`, `ACCUM_FOLD_METHODS`, `SYM_BLOCK_METHODS`,
  `SORT_BLOCK_METHODS`, `NATIVE_PRIMITIVE_SEND_ARITY`, `STRICT_BLOCK_ELEMENT_SHAPES`, `FROZEN_TABLE_NAMES`,
  `TO_ENUM_DIRECT_CLASSES`, `NUMERIC_TO_INT_SENDS`, `NUMERIC_BITOP_SENDS`, ...): each name has hand-written C++
  semantics in a `case` of its emitter. The list says which names that code implements, not what the method does;
  in RBS, an edit could name a method the emitter has no arm for;
- codegen recipes (`INDEX_ARMS`, `INDEX_CLASS_ARMS`, `NUMERIC_SLOW_*`, `NativeCoreDirect::ENTRIES`, `CORE_BODY_EXACT_TESTS`,
  ...): C++ templates with the source text they pin, already checked against 3rd/mruby when the generator runs. RBS
  has no form for a C function body;
- refusal sets (installer, rebinder, reflective and dynamic send names): a superset is always sound and each analysis
  keeps its own;
- tables deliberately narrower than the core tree (`IrTypeFeedback::CORE_PARENTS`/`CORE_MIXINS` leave out Symbol and
  Struct; `EscapeAnalysis` `BUILTIN_SUPERCLASS` adds the exception classes): deriving them would change answers;
- `PROFILER_RESULTS`/Profiler.section (generic block returns) and `LCF_ROW_FLOW` (receiver classes) belong to other
  changes.

## Consequences

- A core fact is edited in one RBS line, and the edit is checked against mruby's sources by a host check that runs
  in about a second, instead of in a constant whose comment says where it was verified by hand.
- The ancestor chains now follow `core_hierarchy.rbs`: a change to the class tree there reaches every chain derived
  from it, and the loaders raise at load time if a chain no longer exists (`FROZEN_TABLE_ANCESTORS` also raises when
  Array and Hash stop sharing their ancestors).
- `sig/native` now holds two kinds of file: native declarations `RbsSignatures` reads (TC1005 notes), and fact tables
  only `CoreFactSigs` reads. A new fact file is added to `CoreFactSigs::FILES`.
- Moving the emitter coverage lists would first need the emitters to dispatch on a declared semantic (for example an
  RBS block-return form), not on the method name; the generic block-return work is the place for that.
