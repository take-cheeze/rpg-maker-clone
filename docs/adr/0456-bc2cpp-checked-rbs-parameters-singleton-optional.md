# 0456. RBS loader: checked class parameters, `def self.` returns and `T?` facts

Date: 2026-10-16

## Status

Accepted

## Context

bc2cpp's whole-program type proofs are moving to RBS declarations that are checked site by site (ADR 0413, 0441).
An attempt to add verified receiver declarations found three loader gaps:

* A `def self.m: ... -> C` signature was loaded under its `Klass.singleton` owner, but nothing read its return:
  the receiver tracer (`trace_new_target`) only looks up a declared return once it has a receiver *class*, and a
  `Klass.m(...)` receiver is a constant. `Game::Message.scan` / `.parse` could not be typed.
* `T?` gave no hint, only an IR nominal bound. Nil-able ivars such as `Combatant#@actions` and
  `ScanResult#@pauses` could not be declared truthfully.
* A class parameter type `(C) -> R` fed ClassAnnotations as a seed. Nothing compared it with the callers, except
  where ArgTypes / ClassArgTypes happened to infer something. Most of these declarations came from CRuby traces or
  from `# bc2cpp:` comments, so they were hints, not facts.

## Decision

**Singleton returns (RBS_SINGLETON_RETURN, `dispatch_targets.rb`).** When the receiver of a `SEND` traces to no
class, and the name has exactly one definition in the whole program (natives included) which is a
`def self.m` with a declared return class, that class is the result. Every call that does not raise NoMethodError
runs that one body, whatever the receiver. The fact has the ret_class contract ("C or nil", guarded).
A singleton signature on a method that exists matches its definition and gives no TC1003 (fixture checked).

**`T?` (RBS_OPTIONAL_HINT, `rbs_optional_hint.rb`).** `Type#optional` holds T's own Type for `T?`. The `T?` Type
itself keeps kind `:other`. Two consumers read it:

* `@x: C?`, `@x: Array[C]?`, `@x: Hash[K, C]?` seed ClassLayout and its element tables exactly like `@x: C`.
  ClassLayout facts are already "C or nil": NIL_TOLERANT_JOIN skips `@x = nil`, so the inference produces such
  facts by itself. Every consumer re-checks the class:
  * TYPED / IVAR_ACCESSOR guards with a by-name, nil or hint-violation else (nil fails `mrb_obj_class == C`);
  * the loop emitters' `mrb_array_p` / `mrb_hash_p` tripwires (nil raises where `nil.each` raises
    NoMethodError);
  * ElementLayout, which treats a `nil` store as no evidence.
  The contradiction check (TC1001, element conflicts) compares the inner T.
* `-> C?` gives ElementAnnotations' `ret_class` C. Its documented contract is already "every non-nil value is C".

Not fed, because their consumers are exact:
* `Integer?` / `Symbol?` (IvarLayout typed slots; FIXNUM_NIL_IVARS stays the reviewed opt-in);
* an `Array?` / `Hash?` return (annotated_array_return admits a proven Array);
* `Array[C?]` elements;
* constructor pools;
* parameters.

**Checked class parameters (RBS_CHECKED_PARAMS, `rbs_param_check.rb`).** After RbsSignatures.apply, every class
parameter that reached ClassAnnotations from a signature (a `# bc2cpp:` comment still wins and is not checked
here) is either verified or removed. Removal covers the ClassAnnotations seed and its IR argument contract.

* Refused, TC1014 at the signature:
  * a POLY name, including every `initialize` (superseded by "Proving more parameters" below);
  * a name in DynamicNames.universe (a computed send, ADR 0279);
  * a name an outside-world (native or foreign Ruby) source spells;
  * a packed (`f(*a)`, `f(*a, &b)`) or keyword caller.
* Verified otherwise. Every call site (CallSiteIndex, `super` and computed `to_enum` sites included) whose
  argument count the definition can take must pass, through all reaching definitions of the argument register,
  one of:
  * `Klass.new` of exactly that class, while no program `new` exists;
  * a call whose every definition declares that non-optional class as its return;
  * a parameter of the enclosing method that is itself a kept, signature-only declaration of that class;
  * `self` in a method body (not a block) of a class nothing subclasses.
  A caller with another argument count raises ArgumentError before the body runs. A name nothing calls holds
  vacuously. Anything else is TC1013 at the call site's file:line. Dropping is iterated to a fixed point, because
  a caller's own parameter only proves an argument while it is kept.
* A build aborts on either error, like any unusable signature. The type check reports them, and never trusts
  the dropped parameter.

TC1013 and TC1014 are new codes. The record-types branch (ADR 0454) owns TC1009.

**Declarations.**
* `sig/bc2cpp/singleton_optional.rbs`:
  * `Game::Message.scan -> ScanResult`;
  * `.parse -> Array[Segment]`;
  * `ScanResult @segments / @pauses` as `T?`;
  * `Combatant @actions: Array[Game::EnemyAction]?`;
  * the checked parameters `Game::Enemy#reseed_rewards(Game::Enemy)` and
    `Scene::Battle#battle_encounter_lines(Game::Troop, untyped)`.
* The existing parameter declarations keep their types. Those the check cannot prove yet (every `initialize`,
  which is POLY; Interpreter#execute and the `do_*` methods fed its `cmd`; #range; the Vehicle / Picture helpers;
  `promote_to_leader`; `weapon_attack_multiplier`; `LCF::Array2D#[]=`) are TC1013 / TC1014 errors, to be resolved
  by making the code or the checker prove them, not by untyping the declaration.
* The ivars those `initialize` parameters fed are declared `T?` in `sig/bc2cpp/nilable_ivars.rbs`, each checked
  against every writer and construction site:
  * `@state` of the Interpreter, EnemyAi and eleven scenes;
  * `@db`;
  * `@party`;
  * `Game::Map@unit`;
  * Scene::Base `@parent` / `@db` / `@map_tree`;
  * `Scene::Battle@map`;
  * `MapWorld` / `VehicleWorld` `@scene` / `@rng`.

### Proving more parameters (RBS_CHECKED_PARAMS, second step)

The first step refused every `initialize`, every POLY name and every name an outside source spells, and accepted
only four kinds of writer. The checker now proves more, by these rules (`rbs_param_check.rb`):

* **`initialize` through its constructor entries.** An initialize is entered by `Klass.new` and by `super`, not by a
  SEND of its name. CONSTRUCTOR_POOLS (ADR 0313) already enumerates those entries in the closed world and refuses a
  body anything else may enter: an unresolved `new` its arity admits, a Symbol, String, alias or `send` naming `new`
  or `initialize`, a Ruby `new` or `allocate`, a mixin on Class, a class an outside source spells, a bare `super`, a
  splat or short keyword `new`. A CodeGen built with `analysis_only: :constructor_sites` answers
  `constructor_entry_sites`. Each entry is checked like a call site (argument k is register receiver + k); a
  refused body is TC1014 naming the pool's reason. Only mandatory positions are entry facts, so a declaration on an
  optional position is refused. A `new` whose receiver traces to one class whose initialize is another body is not
  an entry of this one (the pool keys constants by their last segment).
* **POLY names.** A definition is checked against every call site of its name whose argument count it can take.
  A site of another count raises ArgumentError before any body that cannot take it runs, so it cannot reach this
  one. Every other site may reach it and must pass its declaration, which is what each definition's own check
  requires. No receiver class is assumed.
* **Names an outside source can call.** The token scan is replaced by the names outside code can call a method by:
  in a native source with comments dropped, every string literal, every MRB_SYM-family token and the hooks the VM
  calls implicitly (ClosedWorld::IMPLICIT_HOOKS); in a foreign Ruby source the closed world does not compile, every
  code token and every string or symbol whose whole content is a name (Prism lexer; comments and prose strings are
  not names; a source Prism cannot lex is read bluntly). A C identifier that shares the name is no call: a native
  reaches a Ruby method only through a Symbol.
* **Operators and aliases are refused.** An operator (`[]=`, `+`, ...) is called by VM instructions (SETIDX, ADD, ...)
  and natives that the call-site index does not list. Both names of a keyword `alias` are refused (`alias_method`
  spells Symbols, which DynamicNames already refuses).
* **Exception edges.** The reaching definitions include handler edges (`through_handlers`), so an argument read
  inside a `begin`/`rescue` range is traced on every path, normal or handler. A query that runs out of states is
  retried once with sixteen times the bound; the bound limits work, never the answer.
* **Ivars (GETIV).** `@x` read in a method of class K (blocks included) is `C` when every SETIV that can write the
  slot stores a value proven `C`, and no read can see it unassigned. NUMERIC_IVAR_PROOF's group (ADR 0276) holds
  every SETIV of the name in K's class family and fails when anything else may write it (an outside source spelling
  it, a Symbol or String naming it, a self-rebinding block, an attr_writer, a wild family, reflection).
  INIT_ASSIGNED (`numeric_ivar_assured?`, ADR 0261) proves that every constructor of K and its descendants assigns
  it before it is read, `self` escapes or the frame exits, and that nothing calls `allocate`. A store in a method of
  a class W is kept only when W is K, an ancestor or a descendant of K: in a tree of classes no other object is an
  instance of both. A store in a module's method is always kept. A store that reads the slot back is assumed `C`
  while it is being proven (induction over the stores executed); an answer reached under such an assumption is not
  cached.
* **attr_reader calls.** A call whose every definition is either a declared `-> C` or an attr_reader is `C` when the
  ivar rule proves each reader's slot `C` for the reader's class.
* The diagnostic now says why a reaching-definitions query failed, and a parameter of a method with no signature
  is no longer called a block parameter.

**Direct construction of an inherited initialize (INHERITED_DIRECT_CONSTRUCT, `codegen_send.rb`).** The direct
construct arm (`bc2cpp_direct_alloc` + `<Owner>_initialize_impl`) required the class's own initialize. It now takes
the initialize the superclass chain resolves to (`direct_construct_init_def`) when every class the lookup passes is
a declared class with no unresolved mixin, no included module defining initialize, nothing prepended
(`numeric_init_definition`), no outside source spelling it, and no unregistered DEF installs an initialize. The
other conditions of the arm are unchanged (stable constant, standard constructor lookup, no singleton `new` or
`allocate` on the chain, the arity check, a clean compile), as is the class-identity guard of an unstable constant.
A chain that reaches Object without a Ruby initialize, and a native initialize, keep `mrb_obj_new`: a native body
reads its arguments from a VM frame and cannot be called bare, and which native initialize Object resolves to is not
a fact the closed world records. This is a closed-world arm only.

**Declarations.** `Game::Interpreter#do_change_exp`, `do_change_level`, `do_change_hp`, `do_change_mp`,
`do_full_heal`, `do_simulated_attack`, `do_change_condition`, `do_change_class`, `do_change_battle_commands`,
`do_change_params`, `do_change_skills` and `do_change_equipment` declare `(LCF::EventCommand cmd)`: each is fed
`#execute`'s `cmd`, and their `#stat_targets(cmd)` calls trace to it.

**Still unproven (errors, not holes).**
* `LCF::Array2D#[]=(Integer, LCF::Array1D)`: an operator, called by every SETIDX; its body accepts nil, a String
  and any Array1D, so the declaration is narrower than the method's own contract.
* `Scene::SaveLoad#initialize` position 2 `Game::State`: `Scene::Title` (title.rb:183) and `Scene::Map` (map.rb:4746)
  pass `nil`. The declaration is false.
* `Game::Interpreter#execute`: `cmd = @list[@index]` needs an element proof of `@list`, which no checked fact gives
  before ClassLayout; the `do_*` methods it feeds follow.
* `Game::State#vehicle` is `@vehicles[type]`, a Hash read that answers nil for a key it lacks, so it cannot be
  declared `-> Game::Vehicle` and pass DECLARED_RETURN_CHECK.
* `Game::Party#promote_to_leader`: the argument is `Enumerable#find`'s result, nil when nothing matches.
* Readers of `RPG2k@db` and `Scene::Map@rng`: INIT_ASSIGNED does not prove that every constructor assigns the slot
  before `self` escapes.

### Proving more parameters (third step): nil narrowing, checked `C?` returns, captured parameters

The second step left 72 TC1013 / TC1014 errors that are not about constructor sites. This step adds four rules and
fixes one false declaration. It also closes a gap: the checker trusted every `-> C` signature, including the
`%a{bc2cpp:hint}` ones that DECLARED_RETURN_CHECK (ADR 0455) never checks (`Actors#existing -> Game::Actor` reads a
Hash and can return nil).

* **Only checked return declarations prove a call (`rbs_param_check.rb`, returns_why).** A call is C when every
  definition of its name is an attr_reader of a proven slot or has a DECLARED_RETURN_CHECK entry `-> C` or `-> C?`
  (`CodeGen.declared_returns`, passed in as `declared_returns:`). A `%a{bc2cpp:hint}` declaration and one whose
  parameter count is not the definition's are not checked, so they prove nothing. This is sound because DECLARED_RETURN_CHECK verifies every return path of each
  entry and aborts the build (or reports TC1010 to the type check) when one fails. A `-> C` entry is checked with
  no nil path, so it proves "exactly C". A `-> C?` entry proves "C or nil".
  Since ADR 0455's DECLARED_RETURN_GUARD, a `%a{bc2cpp:hint}` declaration is an entry too: its compiled body checks
  every returned value and raises on a mismatch, so it proves the same. `Actors#[]` and `#existing` are now
  declared `-> Game::Actor?`, which is what they return.
* **NIL_NARROWING (`nil_narrowing.rb`).** When a reaching definition of the argument is only "C or nil", the
  argument register must also be proven non-nil at the call. This is a forward must-analysis over the irep's
  normal and handler edges. The state is the set of registers that cannot be nil on entry to an instruction. The
  method entry proves none, and a join keeps what every incoming edge proves. Along an edge out of instruction p:
  * every register p may write is dropped (`Program#may_write?`, the reaching-definitions model: a write, a callee
    frame below the register, an unmodelled op);
  * `MOVE a b` copies b's fact to a;
  * the edge only a non-nil value takes adds the tested register: the fall-through of `JMPNOT r` (`if r`) and
    `JMPNIL r` (`r&.`), and the jump of `JMPIF r` (`return unless r`, `next unless r`). An edge that is both jump
    and fall-through adds nothing;
  * the normal return of `SEND r :m` (SEND, SEND0, SENDB) adds the register r was copied from, when nil cannot
    answer m (`CodeGen#nil_unanswerable?`, ADR 0296: no Ruby, foreign or native definition of m on NilClass,
    Object, Kernel, BasicObject or a module they include, no method_missing there, no computed install). `nil.m`
    then raises NoMethodError, so a call that returned had a non-nil receiver. A test of a register copied from a
    local narrows the local the same way. "Copied from b" means the nearest writer of r is `MOVE r b`, it reaches
    the call on every path (`write_dominates?`) and nothing between may write b;
  * a handler edge (p raised) drops what p may write and adds nothing. A JMPUW edge proves nothing, because an
    ensure body may run on the way. A register a nested block SETUPVARs is never proven.

  The value at the use is one of the reaching definitions, each C or nil, and it is not nil, so it is C.
  `x.nil?` tests are not modelled. That would need a proof that `nil?` on nil is mruby's own `NilClass#nil?`, and
  no remaining site needs it.
* **Captured parameters (GETUPVAR, upvar_why).** A block's read of a slot of the method that created it
  (`r.each { operand_value(cmd) }`) is that method's parameter when all of these hold:
  * the method never writes the register (`may_write?` on every instruction, the model entry_why already uses);
  * no nested block SETUPVARs it;
  * nothing in the build can write a local by name (`captured_local_writers_absent?`: binding,
    local_variable_set, eval).

  The captured slot then holds the entry value for the block's whole life, even after the method returns, and
  the parameter must be a kept declaration (entry_why).
* **SEALED_HASH_IVAR (`codegen_sealed_containers.rb`, in DECLARED_RETURN_CHECK).** A `-> C?` declaration also
  accepts a return path whose value is `@h[k]` (GETIDX on a GETIV) when the Hash in `@h` cannot be reached any other
  way and every Hash stored there held only exactly-C values:
  * every SETIV that can write `@h` for the reader's class (`ivar_store_sites_of`, NUMERIC_IVAR_PROOF's group
    without INIT_ASSIGNED) stores nil or the result of a `HASH` literal directly before it. That literal's register
    is overwritten unread after the store, and each of its values is exactly C by the declared-return class trace,
    in the storing method's frame;
  * every GETIV of the name anywhere in the program feeds only a GETIDX on its own register, in straight-line
    code, through loads that do not read it;
  * there is no attr_reader of the name;
  * there is no `instance_variable_get` the closed world cannot see (no computed send of it, no outside Ruby token,
    no native but its mruby-metaprog registration). A literal `:@h` already fails the group;
  * there is no `ObjectSpace.each_object`;
  * nil cannot answer `[]`, so an unassigned or nil `@h` raises.

  OP_GETIDX on an exact Hash is `mrb_hash_get` (vm.c), which runs no method of the Hash and answers a stored value
  or, for a missing key of a Hash without a default, nil. Nothing can give the literal a default without a
  reference to it, so the read is exactly C or nil, and only a nilable declaration may take it.

**Declarations.**
* `Game::State#vehicle: (untyped type) -> Game::Vehicle?` (`checked_returns.rbs`). Its body is `@vehicles[type]`,
  and @vehicles is the sealed `{ boat: Vehicle.new(:boat), ... }` literal. With NIL_NARROWING, `Scene::Map#
  draw_vehicles` proves its `vehicle_charset(v)`, `vehicle_charset_index(v)` and `draw_vehicle_frame(.., v, ..)`
  arguments: `v.placed?` (nil has no `placed?`) runs first on every path.
* `Game::Actor#weapon_attack_multiplier: (LCF::Array1D? it)`. The `(LCF::Array1D it)` declaration was false:
  `#strike_count` passes `equipped_weapons.first` of an unarmed actor's empty list, and the body starts
  `return 1 unless it`. nil is part of its contract, so this is a wrong declaration, not a nil hazard in the code.
  A `T?` parameter gives no seed (above), so its three errors (the `#first` result, the `reduce` block parameter,
  the `w1, w2 = weapons[0, 2]` AREF) are gone with the false claim. The elements come from `@db[:item][iid]`, an
  untyped `LCF::Array2D#[]` read, so no element rule could have proven `LCF::Array1D` anyway.
* Already resolved by the previous commit:
  * `Game::Party#promote_to_leader(Game::Actor?)`: a `T?` parameter is not a checked class parameter, so the
    `find` result needs no proof (the body begins `return unless actor`);
  * `LCF::Array2D#[]=(Integer, (LCF::Array1D | String | nil))`: a union is not a checked class parameter either,
    so the operator refusal (which only concerns checked class positions) no longer fires.

**Still unproven (errors, not holes).**
* `Game::Interpreter#execute(LCF::EventCommand)` and the ~60 errors that follow from it: every `do_*` method,
  `stat_targets`, `range`, `picture_coord`, `picture_name`, `eval_condition`, and `operand_value` (whose GETUPVAR
  now passes, leaving only `do_control_vars`' own unproven `cmd`). `cmd = @list[@index]` needs "every element of
  every Array @list can hold is an EventCommand", and that is not provable soundly with the closed world's facts:
  * @list is written from `commands || []` in `#start`, from `cmds` in Call Event / Call Common Event, and by
    `@list, @index, @call_frame_event_id = @call_stack.pop`;
  * `#start`'s callers pass `ev.commands`, `ce.commands`, `p[:commands]`, Battle's `cmds` and the save file's
    `innermost[:commands]`;
  * `resolve_call` reaches `EventResolver#map_event_commands` / `common_event_commands`, which end in
    `LCF::Array1D#[]`, a schema-driven `LCF.to_rb` decode with no static element class;
  * the call stack is an Array of 3-element Arrays (a tuple type the checker does not have);
  * the Arrays are shared, so an element proof would also need every mutation through an alias. Array1D caches
    its decode and hands the same Array to every reader, `do_call_event` pushes @list onto @call_stack, and
    `call_stack_snapshot` exports it as `commands: @list`. SEALED_HASH_IVAR's "never leaves the ivar" does not
    hold.

  Even with an element fact, `break if @index >= @list.size` does not prove `@list[@index]` non-nil, because a
  negative `@index` past `-size` reads nil. The in-engine writers keep it non-negative: `start_at` and
  `restore_call_stack` test the index, and the rest store 0, a size or a scan target, add 1, or subtract 1 after
  an earlier add. One writer is unguarded. The outer frames `restore_call_stack` rebuilds take a save file's
  `current_command` (a schema `:int`) as is, and `return_from_call` pops it into @index. A crafted save with a
  negative value there would make `execute(nil)` raise NoMethodError. No integer-range proof over ivar writers
  exists to rule this out, so it stays a missing proof. The save-file path is the one place a guard is missing
  (`restore_call_stack` checks only the innermost frame's index). Making it provable needs
  checked element types for the LCF decode and for the call-stack tuple, or a checked guard in the code
  (`cmd.is_a?(LCF::EventCommand)`, with an is_a? narrowing rule). Neither is part of this step.
* `RPG2k::Scene::Map#draw_picture(Game::Picture)`, and `toned?` / `toned_picture_src`, which follow from it.
  `p = pics[id]` reads `@state.pictures`, a Hash the `pictures` attr_reader hands out (and legacy_lsd.rb reads),
  so SEALED_HASH_IVAR does not apply. `p.shown?` would narrow nil away, but the class needs an element proof of a
  Hash that leaves its ivar.

**Not added.**
* Element rules for `Enumerable#find`, native `#first` and AREF / GETIDX of a proven `Array[C]`. No remaining
  site has a proven `Array[C]` source; the two sites that used them were false or `T?` declarations.
* The checker still assumes, as the second step did, that the registry lists every definition of a declared
  return's name. DECLARED_RETURN_CHECK records a foreign or native definition as an info (no fact), and the
  parameter check does not yet read that. Refusing every name an outside source spells (`outside_call_names`)
  would be sound, but it would also drop declarations such as `Game::Message.scan`, whose name foreign Ruby
  spells as String#scan.

**Checks.** `scripts/bc2cpp/join_dominance_check.rb` (host part, a few seconds, no mrbc) now holds the
NIL_NARROWING cases:
* `if v` (taken arm, MOVE copy; the else arm and before the test are negative);
* `return unless v`;
* a successful call nil cannot answer (the receiver's source register, not the result register);
* negatives: a call nil may answer, a rescue edge out of the call, a write between test and use, a join with an
  untested path, a callee frame below the register.

SEALED_HASH_IVAR and the GETUPVAR rule need a closed world (CodeGen tables), so they have no host-only home.
Their cases, for a fixture build:
* positive: `@h = { a: C.new }` read only as `@h[k]` with `-> C?`; a block reading its method's untouched
  parameter;
* negative: `-> C` (not nilable); a second store of a non-literal Hash; `x = @h` (a read that escapes);
  `attr_reader :h`; a computed `instance_variable_get`; a HASH literal passed to a call before the store; the
  method reassigning the captured parameter; a nested block SETUPVAR of it.

### Proving more parameters (fourth step): checked runtime guards (IS_A_GUARD)

The third step left two spots where no static fact gives the argument's class: `Game::Interpreter#update`'s
`cmd = @list[@index]; execute cmd` (about 60 errors follow from it through the `do_*` methods) and
`Scene::Map#draw_pictures`' `p = pics[id]; draw_picture p, ...` (and `toned?` / `toned_picture_src`). Both now
check the value at run time, and the checker narrows on the check.

**Engine.** Each spot raises a TypeError naming the bad entry before the call. Valid data behaves as before.
* `interpreter.rb`: `raise TypeError, "event command #{@index - 1} is #{cmd.class}, not LCF::EventCommand"
  unless cmd.is_a?(LCF::EventCommand)`, between `@index += 1` and `execute cmd`. It is the only path to the call.
* `scene/map.rb`: `raise TypeError, "picture #{id} is #{p.class}, not Game::Picture" unless
  p.is_a?(Game::Picture)`, before `draw_picture p, cam_x, cam_y if p.shown?`. A nil entry used to raise
  NoMethodError on `shown?`; it now raises this TypeError.

**Rule (NIL_NARROWING, `nil_narrowing.rb`).** The state also holds class facts, pairs `[register, K]`. They are
dropped, copied by MOVE and met exactly like the non-nil facts. Two edges are new:
* the truthy edge of `JMPIF t` (its jump) or `JMPNOT t` (its fall-through) adds `[b, K]` and b's non-nil fact,
  when all of these hold:
  * the instruction before the test is `SEND t :is_a? n=1` (or `:kind_of?`);
  * that SEND is the test's only predecessor, handler edges included, and its edge into the test is not a
    handler edge. So t is that call's own result;
  * the receiver t was copied from b (`copy_source`, as for a call nil cannot answer), and neither the SEND nor
    the test may write b;
  * `CodeGen#is_a_guard_class` names K for that SEND (below).

  `raise ... unless x.is_a?(K)` is `JMPIF` over the raise, and `if x.is_a?(K)` is `JMPNOT` into the else arm.
* the normal edge out of a `raise` SSEND proves everything (no value takes it), when `CodeGen#raise_never_returns?`
  holds: Kernel's native raise (kernel.c `mrb_f_raise`, which ends in `mrb_exc_raise` whatever it is given) is
  the only definition (`class_test_name_safe?('raise')`). mrbc lays the raise's fall-through into the guarded
  code, so without this the join after the guard would drop the fact. This is CLASS_NARROWING's
  `class_narrowing_noreturn_call?` rule.

Exception edges add nothing, a JMPUW edge proves nothing, and an op `may_write?` cannot model drops the fact. These
are the existing edge rules.

**`CodeGen#is_a_guard_class`.** It answers K only when a true answer makes the receiver an instance of exactly K:
* `class_test_name_safe?` holds for the name (CLASS_NARROWING's audited test). There is no Ruby, foreign Ruby or
  computed definition, alias or undef of `is_a?` / `kind_of?` anywhere, and its native registrations are Kernel's
  alone. No declared, dynamic or foreign subclass of BasicObject exists, so no receiver lacks Kernel's method and
  method_missing never sees the call. Every receiver then runs `mrb_obj_is_kind_of`, which is true exactly when K
  is in the receiver's class chain. A singleton class or an extended module cannot add a class to it.
* the argument is a straight-line `GETCONST` / `GETMCNST` chain that no branch bypasses
  (`straight_line_constant_name`), spelling `K` or `Root::K`. `ClosedWorld#is_a_guard_constant?` must prove that
  the spelling names exactly the declared class K wherever it is evaluated:
  * the root is bound once. The closed world declares exactly one class or module of that simple name, at top
    level. No bytecode SETCONST writes the name, and there is no dynamic constant mutation. No foreign Ruby
    source spells it. No native binds it except by a top-level `mrb_define_class` / `mrb_define_module`, which
    reopens that same constant. A nested define, const_set, const_remove, global or class const, or a binder whose
    name is not spelled out refuses. GETCONST then finds that one binding from any scope, so const_missing is
    never asked;
  * `Root::K` is found in Root's own constant table, where its declaration put it, before any ancestor or Object;
  * K is a declared class that is not opaque (not rebound, not dynamically subclassed, no outside file
    reopening it). It has no declared, unresolved (`wild`) or foreign Ruby subclass, and no SETCONST of its
    simple name.

  The constant tables of the code generator (ConstructClassNames, StableClassConstants) are built after this check
  runs, so it does not use `constant_object_owner`. It uses its own stricter rule instead.

**Use (`rbs_param_check.rb`).** `trace` first asks `NilNarrowing.instance_of?(irep, idx, reg, C)`. When every path
to the call site proves the argument an instance of exactly C, and nothing in `superclass_of` inherits from C (the
`self` rule's check), the argument is proven. The declared class is an exact-class fact: `Klass.new` must be
exactly C, and `self` needs a class nothing inherits from. So a K strictly below C is not accepted, and K must be
C. Since K has no subclass, "an instance of K" is "exactly a K".

**Soundness.** At the call, the argument register holds the value that a completed, true `is_a?(K)` was sent to.
No write to the register or its copies happened on any path in between. The test ran Kernel's
`mrb_obj_is_kind_of` against the one class object K's spelling can denote. That class has no subclass, so the
value's class is K.

**Checks.** The host part of `scripts/bc2cpp/join_dominance_check.rb` (no mrbc) holds the IS_A_GUARD cases. They run
on a real ClosedWorld and CodeGen; only the native registration scan is stubbed:
* `raise ... unless x.is_a?(K)` proves the argument copy at the call and the local after the guard;
* `if x.is_a?(K)` proves the taken arm;
* negatives:
  * before the test;
  * a guard on another register;
  * a program defining `is_a?` in Ruby;
  * a K that is a call result, not a constant;
  * a K with a subclass;
  * a Ruby `raise` (it may return);
  * after the `if`'s join;
  * a test that another edge also reaches.

**Expected.** The `execute` error at interpreter.rb:724 and the `draw_picture` error at map.rb:11126 are proven. The
errors that only followed from those parameters then clear: the `do_*` methods, `play_audio`, `range`,
`operand_value`, `stat_targets`, `picture_coord`, `picture_name`, `eval_condition`, `toned?` and
`toned_picture_src`.

### Proving more parameters (fifth step): constructor-site chains, block self, Profiler.section values

After the third step, the maix closed-world build reported 106 TC1013 errors. 68 of them belong to the
`execute` / `draw_picture` chains above. The other 38 come from nine roots; every other error in that set
follows from one of the roots.

**Reading a chained reason.** A reason such as `parameter 2 of RPG2k::Scene::Map#initialize is declared
Game::State`, or `@state = (parameter 2 of ...) at map.rb:458`, means that parameter was already dropped in an
earlier round of the fixed point. entry_why answers nil for a declared parameter while `kept?` holds. ivar_why
traces each SETIV into that same entry_why, and its cache lives for one round only. So ivar-store chains already
take part in the co-inductive fixed point: every declaration is assumed first, and one that fails is removed
until nothing changes. The chained errors were refusals that cascaded from the roots, not chains left
unresolved. The fixed point needed no change. Fixing the roots removes the cascades.

**Roots and fixes.**
* **`RGSS::Profiler.section(...) { ... }`'s value.** This root covers `state` in RPG2k#start_new_game, which
  flows to Scene::Map, MapViewer and ChipsetEditor. writer_why sent the SENDB to returns_why, and that rejected
  the native `section`. PROFILER_RESULTS (`codegen_profiler_results.rb`) already pins the native: profiler.cxx,
  SHA-pinned, returns `mrb_yield_argv`'s value. It also pins the literal block, whose exits are plain returns.
  block_value_why now traces every RETURN of the block with the same rules, and any other exit refuses.
  profiler_result_body needs ClosedWorld#stable_constant_identity?, which reads UniqueClassNames and
  ConstructClassNames. bc2cpp.rb now builds both tables before RBS_CHECKED_PARAMS rather than after it. Their
  inputs (ireps, the native and foreign sources) are already final at that point. new_why's trace_new_target
  reads them too, so the parameter check now sees the same tables as codegen.
* **BLOCK_SELF (`codegen_block_self.rb`, `block_self.rb`).** This root covers `MapWorld.new(self, @rng)` and
  `VehicleWorld.new(self, @rng, type)`. They run inside `RGSS::Profiler.section { }` and
  `TYPES.each_with_object({}) { }` in Scene::Map#initialize. `self` in a block is the creating method's self
  unless something runs the block under another self: instance_eval/exec, class_eval/exec, module_eval/exec,
  define_method, Class.new / Module.new / Struct.new / Data.define (mruby's mrb_yield_with_class callers). The
  rule walks the nesting chain from the block up to the method, and each level must pass:
  * the BLOCK is the instruction right before the SENDB/SSENDB that takes it (plain fixed argc, block register
    dest + n + 1), so that call is the only code the Proc reaches. A LAMBDA refuses;
  * the call is either the pinned `RGSS::Profiler.section/frame` (mrb_yield_argv keeps the Proc's self) or a name
    whose every definition only calls the Proc. That means the registry's definitions plus the interpreted core
    bodies the registry drops (`CodeGen.block_self_bodies`). A native refuses, and an attr accessor ignores the
    block. The name also needs no definition out of sight: nothing the closed world cannot place
    (`unknown_def?`), and nothing in an outside Ruby source the build does not compile
    (`CodeGen.block_self_unread_names`). Every method_missing must be mruby's native one (it raises) or a plain
    yielder.

  A plain yielder (BlockSelf.plain_yielder_why) lets the Proc-holding registers be read only as a copy (MOVE), a
  truth test, the receiver of `call`, or the block a BLKCALL (`yield`) runs. The arguments of that call must not
  hold the Proc. The Proc-holding registers are:
  * the block slot from ENTER;
  * every copy of it (reaching definitions follow MOVEs, handler edges included);
  * a nested block's GETUPVAR of a captured slot that may hold it;
  * a BLKPUSH.

  Anything else that reads one refuses: an argument, a return, a store, or an operator's register window (taken
  as the lowest listed register up to nregs). SUPER and ARGARY refuse, because they pass the frame's block on.
  Proc#call and BLKCALL run the Proc under the self it closed over. The world-wide preconditions are:
  * `captured_local_writers_absent?` (no binding or eval can read a local);
  * no Ruby `call` on Proc's lookup path (Proc, Object, Kernel, BasicObject and their mixins);
  * no unresolved mixin there.

  mruby-enum-ext's `each_with_object(obj, &block)` passes: it copies `block` to a local, tests it, and calls it
  from a nested `each` block. The LOADSELF is then the method's self, and the existing rule applies: the owner is
  the declared class and nothing inherits from it.
* **INIT_ASSIGNED for `RPG2k@db`** (GETIV, and the `RPG2k#db` reader for `Game::Shop` / `Game::EnemyAi`). The
  rule is intraprocedural: an ivar read may be seen before it is assigned once `self` is exposed (a self call, a
  block, LOADSELF), even when the callee never reads it. RPG2k#initialize called `native_test_play?` and then
  `db_path` (both self calls) before `@db = ...`. Neither reads @db, so no unassigned read was possible. This was
  a missing proof, not a nil hazard. The fix:
  * `@db` is now assigned first in #initialize, before any call on self;
  * its path comes from a class method `RPG2k.db_path`. The instance `#db_path` delegates to it, because
    Scene::ChipsetEditor uses it.

  The order change has no effect: the two moved lines only read `args` and `TEST_PLAY`.
  `scripts/wio/strip_inline_helpers.rb` now inlines the new line and deletes both definitions.
* **INIT_ASSIGNED for `Scene::Map@rng`.** `@rng = Game::Rng.new(0x2000)` came after several Profiler blocks and
  self calls in Scene::Map#initialize. None of those calls read @rng (its only readers are the world adapters, the
  encounter methods and the `rng` reader Scene::Battle uses), and Map has no subclass. The fix moves it to directly after `@state = state`.
  `@interpreter = Game::Interpreter.new(@state)` moves with it, for the `drive_battle(@interpreter)` below.
  Interpreter#initialize only stores ivars and builds its own Rng, and nothing earlier in the constructor reads
  @interpreter. Neither move changes behaviour.
* **Missing declarations, now checked.**
  * `RPG2k#load_save_state: (?untyped slot) -> Game::State?`. The `?` is the true contract. A missing file
    (`return nil unless File.exist?`) and the rescue both return nil. #continue_game's `return unless state` is
    the NIL_NARROWING that proves `Scene::Map.new(self, state, ...)`.
  * `Game::State.from_lsd: (LCF::Database db, untyped save) -> Game::State`. Its one return path is `state`.
    `state = new(party, ...)` (an implicit-self `new`, which trace_new_target does not resolve) is now
    `Game::State.new(party, ...)`. That is the same call, since nothing subclasses Game::State, and
    DECLARED_RETURN_CHECK can prove it.
  * `RPG2k#open_map_editor` / `#open_chipset_editor: (Game::State)`. Their one caller passes start_new_game's
    `state`.
  * Scene::Title, GameOver and every scene that declared `untyped` now declare `RPG2k` as parameter 1. Each scene
    passes it to `Scene::Base#initialize: (RPG2k)`. Every constructor site passes RPG2k's own `self` or a
    scene's `@parent`, which Base#initialize stores from that checked parameter. GameOver's optional state stays
    `?untyped`.
  * `Scene::Map#drive_battle: (Game::Interpreter)`. Its optional parameter `it = @interpreter` became a
    mandatory one, and #update's call passes `@interpreter` explicitly. An optional position is not a checked
    class parameter. `Scene::Map#drive_parallel_wait: (untyped, Game::Interpreter)` is declared too.

  No declaration was false; each one above replaced `untyped` or nothing.

**Still unproven (errors, not holes).** `drive_parallel_wait`'s `it` is `p[:interp]` in #step_parallel. The
`p` comes from the `@parallels` Array of Hash records that #new_parallel builds with
`interp: Game::Interpreter.new(...)`. No rule proves an element of an Array ivar's Hash records yet. That GETIDX
is now the one root of this chain: `drive_parallel_wait` (2 sites), `drive_battle` (1 site) and
`Scene::Battle#initialize` parameter 3 (2 sites).

**Checks.** `join_dominance_check.rb`'s host part has a BLOCK_SELF section built from mrbc's own bytecode:
* positive: mruby-enum-ext's `each_with_object`; `yield x` (BLKPUSH + BLKCALL);
* negative: returning the block; `instance_exec(&b)`; `@b = b`; the block as an argument; a nested block that
  stores the captured block; a zsuper.

## Consequences

The measurement is the shipped wio pass, against master f256da4f. Comment lines are excluded.

| | master | this change |
| --- | --- | --- |
| `bc2cpp_send(` | 1824 | 1838 |
| `mrb_funcall*(` | 384 | 383 |
| `STRICT_HINT_SITE` | 34 | 20 |
| receiver-fact comment markers | 1303 | 1292 |

* The strict rule costs receiver facts. It is a net loss: about 90 typed accessor sites, mostly
  `LCF::EventCommand` in the Interpreter's `do_*` bodies (41 → 4) and the Vehicle / Picture helpers.
* The `T?` ivars restore nearly all of the `Game::State` facts (426 → 421). They are seeded after the ClassLayout
  fixed point (as every ivar signature is), so facts ClassLayout used to derive *from* a parameter inside
  `initialize` are not restored (for example Scene::Map#initialize's `state.map`).
* Seeding signature ivars into the fixed point itself would recover them. That is follow-up work, because it
  changes every existing ivar signature.
* The new declarations add a few facts: Segment#@text in Message.expand and Game::Enemy#@name in
  battle_encounter_lines. The second is a new forced site, audited and listed.
* Where a declaration could not be proven, the system no longer depends on an unchecked claim. A wrong
  parameter class is now a build error at the caller, not a strict-hint abort at run time.
* Follow-ups that would let more declarations pass (the first three are done, see "Proving more parameters"):
  * constructor-site checking for `initialize` (the allocated class of each `.new`);
  * arity-disambiguated POLY names (`execute` has 1 and 3 parameters);
  * accepting ivars whose every writer is checked;
  * element proofs (`@list[@index]`) and nil narrowing (`return unless state`) before ClassLayout.
