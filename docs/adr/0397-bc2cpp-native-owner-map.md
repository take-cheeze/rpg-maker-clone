# 0397. bc2cpp: native owner map trusts core forwarders

Date: 2026-10-10

## Status

Accepted

## Context

The by-name else of a core exact-class chain (NATIVE_CORE_DIRECT, ADR 0257, and the registered-expression chain of
`compile_native_registered_expression`) sends every receiver the chain's exact-class arms do not name through
`bc2cpp_send`. The earlier census (`scratchpad` funcall breakdown, origin/master 27f18e0f) counted 1020 of the 2060 live by-name sends in method bodies in this class, the largest single cause
(`empty?`, `size`, `to_s`, `length`, `[]`, `key?`, `include?`, ...).

A Ruby definition of such a name on a class C answers an object whose class is exactly C, unless a native
registration lands on C itself. Whether a native lands on C is what the closed world did not record per class:
`ClosedWorld#refusal` answered `:core_or_native` for any name a native source spells. The new owner map
(`tools/bc2cpp/native_owner_map.rb`) reads every native source's `mrb_define_*` family calls and attributes each
registration to a class expression (literal class, core field, class variable, `mrb_class_get`/`mrb_define_class`
path, or a ROM method table installed in the same file). Anything it cannot attribute is recorded as unknown, and an
unknown owner refuses.

mruby's own C forwarders (`define_method`, `alias`, `Module#prepend`, `attr_*` implementations in `3rd/mruby`) install
a name the Ruby program supplies. Those registrations have a computed name and an unknown owner. The closed world
already treats such installs as Ruby-level installs it tracks (`closed_world.rb`, `NATIVE_CORE`: "mruby core's own
computed definitions only ever run for a Ruby-level attr_*/define_method/alias/Struct.new, which scan_closed_world
tracks"). The owner map therefore counts them and, by default, trusts them.

## Decision

1. `NativeOwnerMap` builds the owner map over every native source (`CodeGen.native_source_paths`, the NATIVE_SRCS
   list, not only the sources with a literal name registration).
2. A by-name send of `name` with `n` arguments on a receiver the flow does not prove exact gets, ahead of its by-name
   else, one arm per Ruby definition of `name`: `if (bc2cpp_owner_class_K(M) == mrb_obj_class(M, recv)) { r = C_name_impl(...); }`.
   The else is unchanged. The arm is emitted only when the whole site is proven:
   - every Ruby definition of `name` is an eligible candidate (public, compiled, arity-matching, declared non-module
     class, no prepend on it, no `.singleton`, no ivar accessor, not a core body that would name a project class),
   - no class owns two definitions of `name`,
   - the closed world allows an exact-class arm (`ClosedWorld#exact_arm_refusal`: no global refusal, no dynamic
     installer of the name, no unknown or outside Ruby definer of the name, and no singleton maker, since an object with
     a singleton class is not of its class's exact lookup),
   - and `NativeOwnerMap.verdict` proves, for each candidate class C, that no native registration of `name` lands on C.
   An exact instance of C has C's own definition as its live method (own definitions win over ancestors and included
   modules), so the arm is the dispatch result for that receiver.
3. Core forwarders are trusted by default: computed-name and prepend registrations in `3rd/mruby` do not refuse a
   proof. `BC2CPP_NATIVE_OWNER_MAP=strict` refuses every site while those forwarders exist.
4. `BC2CPP_NATIVE_OWNER_MAP=0` emits none of this; the output is byte-identical to the previous revision (checked).
5. Core bodies compiled into every build name core candidates only (`core_targets`, ADR 0264).
6. Block-carrying sends, sends on a receiver the exact-class flow already proves, and sends whose else is already a
   `bc2cpp_nomethod` get no arm.

No by-name send is removed. The arm adds a guarded direct call in front of the existing dispatch.

## Measurement

Shipped pass, `scripts/bc2cpp_coverage_report.rb` (SKIP_UNSUPPORTED=1), fresh-clone mrbc
(`scratchpad/fresh/build/mruby/host/mrbc/bin/mrbc`), same `3rd/mruby` sources in both trees (the main checkout's
`3rd/mruby` carries uncommitted local patches; both worktrees use a copy of them). Counts taken from the kept
`shipped.cxx` with live lines only (comment lines excluded):

| Quantity | origin/master | this change |
| --- | ---: | ---: |
| `bc2cpp_send(M` calls | 1903 | 1903 |
| `bc2cpp_nomethod(M` / `_named(M` calls | 4504 | 4504 |
| `mrb_funcall*(` calls | 393 | 393 |
| report: cached `bc2cpp_send` / `mrb_funcall_with_block` sites | 2289 | 2289 |
| `// NATIVE_OWNER_MAP` arms in shipped output | 0 | 241 |

Decision tally from the owner map's report (`BC2CPP_NATIVE_OWNER_MAP_REPORT`, one entry per distinct name and arity,
except `arms_emitted`, which counts emissions including ones a caller later discarded):

| Decision | Names |
| --- | ---: |
| proven | 7 |
| `ineligible_candidate` | 237 |
| `no_ruby_definition` | 93 |
| `outside_ruby` | 23 |
| `dynamic_install` | 3 |
| `devirt_blocked` | 1 |
| `owner_native_owner_unknown` | 1 |
| `arms_emitted` | 584 |

The by-name counts do not move, as designed: every site keeps its by-name else. The shipped output changes in two ways:
241 arm sites are added, and the owner-class slot indices (`bc2cpp_owner_class_N`, numbered in emission order) are
renumbered, which changes many lines of the file without changing behaviour. The yield is small: 241 arms against the
1020-site candidate population, because most candidate sets contain a definition the map cannot prove (237 names) or a
name with no Ruby definition to call (93).

## Checks

- `scripts/bc2cpp_native_owner_map_check.rb` (new, generated code only): positive world (a proven site gets
  `if (owner_class == mrb_obj_class) { CxQueue_empty$3f_impl }` with the by-name else kept); negative worlds for an
  unproven native (String defines `empty?` beside its native), an overridden definition (the same class defines it
  twice), a prepend on the candidate, an anonymous class, and a dynamic installer; strict-mode withdrawal; and kill-switch
  byte identity against the same tree at the merge base (`git archive`, copied inside the repository so its closed world
  matches).
- `scripts/bc2cpp_nested_compile_state_check.rb`: `@native_owner_map_targets` is listed in `NOT_PER_METHOD`.
- `scripts/bc2cpp_core_exact_direct_check.rb` and `scripts/bc2cpp_native_core_direct_check.rb`: see the report of the
  run that accompanies this change.

## Not built

- The POLY `compile_poly_*` paths. The candidate sets there already check natives by name; the owner map was wired only
  into the native-core and registered-expression chain elses, where the A1 sites are.
- A per-candidate proof. A site is proven only when every Ruby definition of the name is proven; a single unprovable
  class withdraws the whole site. Per-candidate arms would be sound (the exact-class guard only fires for that class)
  and would raise the yield; they were not built.
- Removal of the by-name else. The arm adds a direct call; the else stays, because a receiver of any other class still
  needs dispatch and no closed-world proof of the receiver set exists here.
- `size`, `to_s`-style names with a foreign Ruby definer. `outside_ruby` is name-level in the closed world; owner-precise
  checks (`ForeignDefiners`) miss definers on receivers they cannot resolve, so the refusal stays.
- Renumbering-stable owner-class slots. The renumbering noted above is a cosmetic consequence of emission order.
