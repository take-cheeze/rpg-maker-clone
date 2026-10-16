# 0455. Checked RBS return and constant declarations

Date: 2026-10-16

## Status

Accepted

## Context

bc2cpp proves return classes with whole-program fixpoints: FIXNUM_RETURN_PROOF, ARRAY_RETURN_PROOF and the class
return fixpoint (RETCLASS_SELF_CALL_SUPPORT). It proves constants with INTEGER_CONSTANT_PROOF and CONST_CONTAINER.
An RBS return declaration (`-> Integer`, `-> Array[C]`, `-> C`) was only a seed. It filled the annotation tables as a
guarded hint and an IR contract, and TC1001 compared it with inference when inference had an answer. Where
inference was silent, nothing checked the declaration. RBS constant declarations were accepted and ignored (TC1005).

## Decision

Return declarations and constant declarations are checked. A declaration that passes adds the fact the matching
proof would produce. A declaration that fails is a located type-check error and aborts the build, as
RBS_SEED_CONTRADICTION does.

### Returns (DECLARED_RETURN_CHECK)

The code is in `tools/bc2cpp/declared_returns.rb` and `codegen_declared_returns.rb`. The checked kinds are
`Integer`, `Array`, `Array[T]`, `C` and `C?`, where C is a class the program defines. Other return types keep
their old role.

The check is modular: it assumes every declaration and then checks every body against those assumptions.
`compute_fixnum_return_names`, `compute_array_return_names` and `compute_class_return_names` seed the admitted
declared names, and their fixpoints never drop a seeded name. Once the fixpoints are final,
`check_declared_returns` verifies every return path of every declared definition. It uses the same predicates as the
proofs:

- **Fixnum:** `fixnum_proof_source?`, or `proven_fixnum_operand?` for entry arguments. The check is Fixnum-exact,
  because the fact allows an unchecked `mrb_fixnum`.
- **Array:** `trace_new_target` returns Array, or `proven_array_source_scan` accepts the value. The scan does not use
  unchecked `# bc2cpp:` comment seeds. A `+` whose left operand is an Array on every reaching definition is also an
  Array (Array#+, with no program `+` on Array or a subclass and no prepend).
- **Class:** `trace_new_target` must name exactly C. `C?` also accepts nil paths.

A call to another declared name is proven by that name's declaration through the seeded sets, so mutually recursive
pairs check together. The build aborts if any check fails, so every seeded assumption has been verified.

The checker looks at these paths:

- each reaching definition of a method-level `RETURN` (`return_value_sources`), which covers explicit returns and
  implicit last expressions;
- `RETNIL`, which covers an empty body and an `if` without `else`;
- `RETSELF`, which proves only C when C is the owner and has no subclass;
- `RETTRUE`, `RETFALSE` and `STOP`;
- every `RETURN_BLK` in nested blocks;
- a `break` anywhere in the subtree, which refuses any path whose value is a block-carrying send's result.

A path the checker cannot follow is an error, not a drop.

The proofs' closed-world preconditions decide whether a checked declaration becomes a name-level fact:

- **Errors:** the name is aliased, installed by `define_method` or undefined, or the program installs methods under
  computed names.
- **Infos (checked per definition, no fact):**
  - outside Ruby or native code defines the name;
  - another definition is native or an accessor;
  - a POLY name is declared on only some of its definitions, or its definitions declare different types;
  - a POLY name is not `name_fully_visible?`;
  - for Integer only, the name is spelled as a literal (FIXNUM_RETURN_PROOF's own rule, ADR 0279).

A POLY name with every definition declared with the same type becomes a fact. FIXNUM_RETURN_PROOF and
ARRAY_RETURN_PROOF are MONO-only, so this is new.

`%a{bc2cpp:hint}` on a method declaration marks a reviewed type that the checker cannot prove. It keeps exactly the
pre-0455 role: a guarded seed and an IR contract. It is listed as `unchecked hint` and never joins a proof's facts.
A compile without `NATIVE_SRCS` and `FOREIGN_RUBY_SRCS` treats every return declaration this way, because
the proofs the check relies on (INTEGER_CONSTANT_PROOF among them) prove nothing there.
Nineteen existing declarations carry it, each with a comment saying why it cannot be checked:

- 12 Integer returns read database rows (Integer, but not a proven Fixnum);
- `Actors#[]` and `#existing` read a Hash, and `#[]` also returns nil;
- `stat_targets` reads an attr_reader;
- `drops` uses `each_with_object`;
- `blockers_at` and `candidates` read a Hash and an ivar;
- `class_battle_commands` relies on an `is_a?` guard.

The alternative was deleting them. A build without them measured +19 `mrb_funcall` (384 → 403) and lost three
strict-hint sites, because `stat_targets`, `blockers_at` and `Actors#[]` feed receiver hints.

### Constants (DECLARED_CONSTANT_CHECK)

The code is in `tools/bc2cpp/declared_constants.rb`, and the check runs at the INTEGER_CONSTANT_PROOF step.

- **`FOO: Integer`:** the declared constant must have exactly one SETCONST. A second one is a reassignment error,
  and an assignment in an unresolved scope (SETMCNST) is an error. No assignment, a jump target on the assignment,
  or a value that does not evaluate is also an error.
  - The value is evaluated as a Fixnum interval over integer literals, other constants, and ADD/SUB/MUL/DIV/ADDI/SUBI.
    DIV refuses a divisor interval that contains 0.
  - A constant read stands for the union of every binding of its bare name, because lexical lookup is not modelled.
  - The bare name joins INTEGER_CONSTANT_PROOF when every binding of it evaluates and no native code, foreign Ruby
    code, class or module binds it. Otherwise the constant is checked but adds no fact (info).
- **`TABLE: Array[...]` and `OBJ: C`:** the one assignment must be an Array (an ARRAY literal, a source the array scan
  accepts, or a `.freeze` of one) or exactly `C.new`. The result feeds CONST_CONTAINER.

The loader's TC1005 "accepted but gives no hint" note is dropped for the constants this checks.

### Diagnostics

- **TC1010** (error or info): a return declaration. An error is reported at the Ruby file:line of the unproven path,
  or at the signature for a refused name.
- **TC1011:** a constant declaration, reported at the assignment's line.

Both are added to the signature diagnostics, so `scripts/bc2cpp/type_check.rb` reports them and exits 1.
`BC2CPP_DECLARED_RETURNS=0` and `BC2CPP_DECLARED_CONSTANTS=0` switch the checks off and add no facts. Without the
outside-world scan, return declarations are listed as not checked and stay seeds.

## Consequences

Measured on the shipped (wio) pass, excluding comment lines:

| | baseline | this change |
|---|---|---|
| `bc2cpp_send(` | 1824 | 1824 |
| `mrb_funcall*(` | 384 | 383 |
| FIXNUM_RETURN_PROOF (`RET`) | 35 | 36 (+`left_panel_w`, POLY) |
| ARRAY_RETURN_PROOF (`ARET`) | 124 | 129 |
| class return fixpoint (`CLASSRET`) | 299 | 299 |
| INTEGER_CONSTANT_PROOF | 701 | 714 |
| `STRICT_HINT_SITE` | 34 | 34 (same list) |

- **ARET:** the five new names are `all_combatants`, `enemy_skill_targets`, `live_members`, `shop_lines` and
  `skill_targets`.
- **CLASSRET:** the baseline was measured with this change's listing and both checks switched off. Every checked
  class declaration was already inferred.
- **Existing declarations:** 30 of the 49 existing return declarations check. Twenty-six add a fact and four are
  checked per definition with no fact. The remaining 19 are `%a{bc2cpp:hint}`.
- **New declarations:** `sig/bc2cpp/checked_returns.rbs` declares `Game::Battle#enemy_skill_targets` and the POLY
  `left_panel_w`. `sig/bc2cpp/checked_constants.rbs` declares 22 layout constants that method bodies read. They are
  integer-literal arithmetic with `*` or `/`, which inference does not evaluate.

Expressibility of the inferred facts was measured on a scratch file, which is not committed. Of 318 engine methods
that TypeFacts infers as returning Integer, Array or a program class:

- 247 pass the checker as fact-carrying declarations;
- 23 pass but carry no fact;
- 48 fail. Most of these are nil paths that the broader inference joins.

Of 56 unproven integer-looking engine constants, 39 check with a fact, 10 check without one (bare-name
collisions or outside bindings) and 7 fail.

The dispatch effect is small because the declarations that matter most for dispatch are exactly the ones the tracers
cannot prove: Hash reads, attr_readers and guard-dependent values. Supporting element-typed Hash and Array reads, and
nil refinement after a `||` test, would move the hints to checked facts. The element class of `Array[C]` is not
checked; it stays the guarded seed it was. `# bc2cpp:` comment returns are unchanged (none remain in the engine).

`scripts/bc2cpp/declared_return_check.rb` (nightly shard `declared-returns`) holds the positive cases:

- Fixnum, Array (with `+`), class, `C?`, mutually recursive classes and a POLY Integer;
- MUL/DIV, Array and class constants;
- `%a{bc2cpp:hint}`.

It also holds the negative cases:

- a nil path, an empty body, a wrong-class subclass path, a wrong kind and an unverifiable call;
- an aliased name, a POLY partial declaration and a failing POLY definition;
- a reassigned constant, a non-Integer constant and a missing constant.

The check runs both through a build and through the type check.
