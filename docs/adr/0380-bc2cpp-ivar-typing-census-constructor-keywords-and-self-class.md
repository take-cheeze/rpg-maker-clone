# 0380. bc2cpp: why ivar class facts fail (a census), keyword constructors, and the class of `self` in pools

Date: 2026-10-10

## Status

Accepted. Supersedes the keyword rows of ADR 0313's refusal table.

## Context

The request: model more and tighten ivar typing so fewer instance-variable class facts are lost, soundly. The earlier
numbers (wio closed world, shipped pass, master `27f18e0f`): `598 CLASS_CANDIDATE_OPAQUE` ivars, and by-name sends whose
receiver is an ivar (ADR 0309, 0378) because the ivar has no class pool. Two different facts carry the name "ivar class",
and the request mixes them, so the first thing the census had to do was separate them.

* **ClassLayout** (`CLASS_HINT`, `class_layout.rb`, ADR 0139): one hint per ivar, joined over the `SETIV` of the *method*
  bodies of its owner by `trace_new_target`. The `OPAQUE` list is the ivars where some store was not traced. A hint is
  a devirtualization *seed*: consumers that need it exact re-check the class at run time (`mrb_obj_class`). It has no
  escape rule list of its own (no `attr_writer`, `instance_variable_set` or block-body stores are looked at) and none is
  needed for what it is used for; ADR 0139 keeps it out of every fixed point for that reason.
* **Class pools** (`CLASSIVAR` / `CLASSARG`, `codegen_class_pools.rb`, ADR 0295/0296/0313/0370): the may-set of exact class
  bits an ivar slot or an incoming argument can hold, joined over *every* store the closed world can make. This is the
  one with the escape list (`NumericIvarGroup#structural`: a native or foreign source spelling the name, a Symbol or String
  spelling it, an `attr_writer`, a wild family, reflection, `define_method` / `instance_eval` rebinding, `Marshal`
  under `=strict`), and it is the one that removes guards from generated code. `bc2cpp_send(` sites with an ivar receiver
  depend on it, not on ClassLayout.

### Census 1: the 598 OPAQUE ivars (new `== ivar-class OPAQUE causes ==` section, `ivar_poison_causes.rb`)

Each unresolved `SETIV` is classified by what its stored register's reaching definitions are (`BytecodeIR.reaching_definitions`
through handlers); an ivar counts once, in the first bucket one of its unresolved stores falls in:

| bucket | ivars | what it is |
| --- | ---: | --- |
| immediate | 175 | every unresolved store is an Integer / Float / `true` / `false` / Symbol / `nil` literal. No registry class names it, so **no class hint can ever hold it**; these are not "fixable", the number is a property of the metric |
| parameter | 166 | an unresolved store is an incoming argument (atoms, overlapping: 76 ivars store a mandatory argument of an ordinary method, 38 of an `initialize`, 63 an optional / rest / keyword one) |
| project_call | 107 | the result of a Ruby-defined method (`clamp`, `int_of`, `max`, `step`, `size`, ... of the project) |
| element_read | 53 | a Hash or Array element (`state[:gold]`, `row[:x]`) |
| core_call | 41 | the result of a native or unregistered method |
| arithmetic | 39 | `+ - / ==` on operands the flow did not type |
| ivar_read | 11 | another ivar whose class is unknown |
| constant | 4 | a constant |
| none | 2 | `RPG2k::Scene::Battle#@rng` / `#@state`: every store is a `nil` literal or a read of the same slot |

So 175 of the 598 are structurally untypeable as a class, and the rest are spread over five causes none of which is above
28%. The request's three suspects: (a) constructor arguments are 38 ivars (6%) of the class-hint view; (b) `.map` /
`.select` on an unknown receiver sit inside `project_call` / `core_call`; (c) Integer results are the 175 + part of the 39,
and need no class bit at all in the pools (below).

### Census 2: the dropped class pools (`BC2CPP_POOL_DROP_REPORT=1`, `send_root_report.rb`)

Of 634 ivar groups with no pool (the others, 314 `CLASSIVAR`, are pooled), 300 failed in the flow, 229 are structurally
refused by an `attr_writer` that the setter-site pools (ADR 0370) could not account for, 71 by a spelled name, 34 are open.
Each dropped group is walked to the *reaching definition* of each store the flow cannot name (a joined register is
attributed to the definition at fault, not to the nearest textual writer, which the older report did and which blamed
literals for joins). The blockers, as pools they appear in (overlapping):

| blocker | pools | notes |
| --- | ---: | --- |
| `GETIDX` element read | 81 | needs element typing; ADR 0285 / 0370 priced it at the size of a new proof |
| a constructor argument at an *optional* position | 58 | positions past the mandatory ones are not candidates (default code may read a later parameter) |
| another ivar with no pool | 34 | transitive |
| `+1` / `-1` / `+` on such a value | 81 | transitive: the operand is a dropped slot or an element read |
| an argument of a POLY name (`start`, `feed`, `initialize` of two classes) | 27 | call sites cannot be attributed to a definition |
| `clamp` / `%` / `step` / `max` / `min` / `size` / `to_i` results | about 60 | the receiver is an Integer the flow knows; the name has a core *Ruby* body (`Comparable#clamp(min, max = nil)`) or a native with no result fact. Weight in by-name ivar sends: about 0 |
| `map` / `select` on a receiver of unknown class | 7 | `Game::State#map` is an `attr_accessor`, so `map` cannot be proven an Array-returner for an unknown receiver; the receiver's own class would have to be proven first |
| `AREF` (multiple assignment) | 19 | tuple data from outside (`@list, @index = @call_stack.pop`) |
| a constructor with keyword parameters, or a keyword `new` / `super` | a few | built here |
| `self` passed as an argument | a few | built here |
| an unmodelled irep (`Interpreter#update`, `do_show_choices`) | 11 | `NumericFlow.states` refuses the irep |

Weighted by the by-name sends that read the slot, the head is `Interpreter#@state` (38 sends) whose root is
`RPG2k.load_save_state` (a `Marshal.load` result) and a keyword-taking `Scene::Base` constructor chain, then
`Interpreter#@list` (23, element reads of a Hash), `@call_stack` (12, `map` over data restored from a save), `Actor#@states`
(10), `Battle#@queue` (8). That is the ADR 0309 conclusion again: the ranking is flat, and the rules below move the
numbers by a handful, not by tens.

## Decision

### 1. IVAR_POISON_CAUSES: the census as a permanent diagnostic

`ivar_poison_causes.rb` (stderr section `== ivar-class OPAQUE causes ==`, always on, no effect on the generated text) and
`BC2CPP_POOL_DROP_REPORT=1` (stderr section `== class pools dropped: causes ==`, `POOL_DROP_STATE` / `POOL_DROP_BLOCKER`)
count what is left. `BC2CPP_IVAR_POISON_REPORT=<path>` writes the OPAQUE list with its bucket. Every refusal below has a
reason string on stderr and is counted (`SITES ... keyword_refused_short=N`, `POOL_SELF_CLASS off: <reason>`,
`CTOR <class>#initialize refused: <reason>` now says which arity shape: `(req=0 opt=22 rest=0 post=0 key=0 kdict=0)`).
`BC2CPP_SEND_ROOT_REPORT` only tags the generated text when it is set itself now, so the pool report can be taken from an
untagged build.

### 2. CONSTRUCTOR_KEYWORDS (kill switch `BC2CPP_CTOR_KEYWORDS=0`)

ADR 0313 refused every `initialize` with a keyword parameter and every `new` / `super` that passes keywords, "to stay clear of
ENTER's hash handling". `vm.c` `OP_ENTER` keeps the keywords of a call in a separate kdict register (`ci->nk`, `regs[kidx]`)
and hands them to a callee with keyword parameters as its kdict; to a callee without, it appends the kdict to the
positionals (an extra *trailing* Hash). Either way argument `k <= n` of a call `new(a1..an, k: v)` is the k-th positional.
So a keyword call is a site of its `n` positionals (`n=10|nk=3` registers `R(a+1)..R(a+10)`), and an `initialize` with
keyword parameters keeps positions `1..mand`.

Preconditions, each a refusal with a reason (counted in `SITES`):

* the call has literal keywords: `n` and `nk` are numbers. `n=*` (a splat) and `nk=*` (`**opts`, a packed kdict) leave the
  count unknown and withdraw the callee as before (`new with a splat or keyword`).
* the call passes at least `mand` positionals (`keyword new with fewer positionals than mandatory parameters`, or
  `super with unmodelled arguments`): with fewer, the keyword Hash would stand in for a mandatory argument of a callee
  without keyword parameters, and the register read would be a key Symbol.
* `post` (a post-mandatory parameter) is still refused, as is a bare `super`, a `new` on a receiver that is not a named
  class, and everything else ADR 0313 withdraws on.

Effect: six more constructors pooled (`Game::Battle`, `Game::Map`, `Scene::Battle`, `Scene::Map`, `Scene::MapViewer`,
`Scene::ChipsetEditor`).

### 3. POOL_SELF_CLASS (kill switch `BC2CPP_POOL_SELF_CLASS=0`)

`LOADSELF` in the table-building flow answered OTHER, so `Menu.new(self, state)` or `holder.owner = self` dropped the
argument or setter pool of the callee. In the body of a uniquely owned instance method of a declared class (the existing
`return_class_method_oracle` conditions: not core, `class_declared?`, `instance_class?`, no other owner of the body, an
`exact_class?` or a fully visible hierarchy of at most eight classes) `self` is exactly that class or one of its
descendants. The flow now reads `LOADSELF` as that class set (`LoadSelfOracle`, which refines `LOADSELF` and nothing else:
register 0 and implicit-receiver calls still answer OTHER).

Preconditions: the body is a *method* irep (a block body keeps OTHER: `instance_exec` may rebind it); and the program does
not rebind method bodies: `instance_method`, `public_instance_method`, `bind`, `bind_call`, `unbind`, and `define_method`
without a literal block withdraw the rule, as does outside Ruby spelling any of them (`POOL_SELF_CLASS off: <send> at
<irep>` on stderr; none occurs in the wio program today). A module method is never given a class.

Effect: `Interpreter#@map_info` (`RPG2k::Scene::Map`), `@battle_screen`, `Scene::Title#initialize arg1`,
`Scene::GameOver#initialize arg1`, `Scene::Battle#initialize arg1`.

### Not built (and why)

* **ClassLayout from ClassArgTypes.** `ClassArgTypes` skips a caller whose argument it cannot trace (`next if found.nil?`)
  and so states a class that the untraced caller may contradict; its own header forbids feeding ClassLayout. Block recognizers
  consume ClassLayout facts with no run-time fallback (`traced == 'Array'` gates), so a hint from it would be unsound. The
  sound source of an argument class is the pool (`CLASSARG`), which enumerates every site; it is computed after ClassLayout.
* **Integer / Float stores.** Already modelled: `NumericFlow` has `INT` / `FLT` bits, `TrueClass` / `FalseClass` / `Symbol` have
  class bits (ADR 0350, `BC2CPP_IMMEDIATE_CLASS_BITS`), nil is a bit. A numeric ivar fails only when its operand is an
  unpooled slot or an element read (`addi`, `add`, `subi` above), i.e. transitively.
* **Optional constructor positions.** Sound only if the default-value code never reads a later parameter, which needs a
  read-set of the ENTER table's default region; not built.
* **Integer-receiver core results** (`clamp`, `%`, `step`): `Comparable#clamp(min, max = nil)` is refused by the
  specialization's arity rule, and a native Integer result table would need a pinned audit of `numeric.c` (ADR 0333-0336
  style). The weight in by-name ivar sends is about zero, so it was not built.
* **`map` on an unknown receiver.** `Game::State#map` is a project `attr_accessor`; the proof needs the receiver's class.
* **Nil-or-X ClassLayout joins and `String` literals.** 13 ivars; ClassLayout has no `String` terminal and a nil arm
  alone was already skipped (NIL_TOLERANT_JOIN).

## Consequences

* Same base, kill switches off against the new defaults (`SKIP_UNSUPPORTED=1`, wio closed world, untagged, symbol-table
  indices resolved to names before diffing; the kill-switch-off build is byte-identical to the base):

  | | base | new | switches off |
  | --- | ---: | ---: | ---: |
  | `CLASS_CANDIDATE_OPAQUE` ivars | 598 | 598 | 598 |
  | `CLASSIVAR` pools | 314 | 318 | 314 |
  | `CLASSARG` pools | 194 | 201 | 194 |
  | constructors pooled | 38 | 44 | 38 |
  | `bc2cpp_send(` | 2082 | 2081 | 2082 |
  | `mrb_funcall*(` | 418 | 418 | 418 |
  | `CLOSED_WORLD_NATIVE_EXACT` arms | 226 | 226 | 226 |
  | generated lines | 444,215 | 444,088 | 444,215 |

  The OPAQUE count does not move because neither rule is a ClassLayout rule; the census above says why the number is the
  wrong target (175 are immediates). 17 of 6,724 functions change: `Scene::Battle` `initialize`, `start`, `finish_battle`,
  `encounter_backdrop`, `battle_encounter_lines`, `select_battle_option` (an ivar receiver of `RPG2k::Scene::Map`, or a
  `BattleRequest`, now exact: the class test and the `bc2cpp_nomethod` arm go), `Interpreter` `character_facing`,
  `do_shake_screen`, `event_operand`, `screen_operand`, `do_store_terrain_id` (exact `Scene::Map` receiver), and six
  functions whose class-chain arms are reordered because class bits are allocated in a different order
  (`Battle.flag_of`, `hit_rate_of`, `strike_count_of`, `Party#skill_cost`, `LCF.encode_move_commands`, a
  `Scene::Battle` result-lines block); the reordered chains test the same classes. Totals: 66 class tests, 20 nomethod arms
  and one `bc2cpp_send(` removed, 20 exact calls added.
* The next lever by weight is a typed element read of the save / state Hash (`GETIDX`, 81 pools) and the `Marshal.load`
  roots of `Interpreter#@state`; both are new proofs of the size ADR 0285 describes.

## Checks

`scripts/bc2cpp_ivar_typing_check.rb` (every positive loses its guard; negatives: a second class at one keyword site, `**opts`,
a splat, too few positionals, a keyword `super` with too few, a bare `super`, a post-mandatory parameter, a `new` on an unknown
receiver, a packed-kdict `new`, an explicit `initialize` call; self from a block, a module method, a class pair, a second
site; an UnboundMethod bind and a `define_method` from a Method object; both kill switches; the two diagnostics) and
`scripts/bc2cpp_ivar_typing_mutation_check.rb` (nine mutants of the conditions above).
