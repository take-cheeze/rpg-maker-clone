- `tools/bc2cpp/bc2cpp.rb`'s whole-program ivar/array-element analyses
  (`ClassLayout`, `ArrayElementLayout`) now distinguish, and report
  separately, two previously-conflated reasons a fact can end up
  poisoned to `UNKNOWN`:
  - **ANY**: two real sites were both traced successfully and genuinely
    disagree -- a proven fact about the program (the ivar really is
    heterogeneous). No annotation could ever fix this; a future
    code-reading round should not spend time on it.
  - **OPAQUE**: at least one real site could never be traced at all --
    an admission of ignorance, not a proven conflict, and the real,
    actionable candidate list for a future annotation round.

  Both `ClassLayout.analyze` and `ArrayElementLayout.analyze` gain an
  optional `poison_reason:` keyword (a caller-supplied Hash filled in as
  a side effect on each ivar's first poisoning transition, default `nil`
  for zero behavior/overhead change) and a new `.unknowns_by_reason`
  filter. The driver reports four new, purely additive diagnostic
  sections (`== ivar-class candidates split: ANY/OPAQUE ==`, `==
  array-element candidates split: ANY/OPAQUE ==`) alongside the existing
  `CLASS_CANDIDATE`/`ELEM_CANDIDATE` lists, which keep their exact prior
  membership and meaning. Whole-program result: **zero** `ANY` entries
  anywhere in the program today -- every one of the 520 poisoned
  `CLASS_CANDIDATE` and all remaining `ELEM_CANDIDATE` entries is
  `OPAQUE`, meaning no ivar in this codebase has ever been proven to
  genuinely hold more than one class; every poisoning traces back to an
  unresolvable expression. That is itself a useful, real finding for
  anyone weighing whether a future round is worth running.

  Also new: `element_value_class` (the per-element-VALUE tracer shared by
  `ArrayElementLayout`/the block recognizers) now recognizes a literal
  primitive value written directly into a traced register -- a `HASH`
  literal (`-> Hash`), a `STRING` literal (`-> String`), any
  `LOADI`/`LOADI_n`/`LOADI8/16/32` Fixnum literal (`-> Integer`), or a
  `LOADSYM` (`-> Symbol`) -- via the new `PRIMITIVE_ELEMENT_CLASSES`
  constant. These are real, resolved facts, but deliberately **never**
  fed to CodeGen (`.known` on both layouts strips them out exactly like
  `UNKNOWN`, since neither `Integer`/`Hash`/`String`/`Symbol` is ever a
  real `known_owners` registry entry, and every consumer's runtime guard
  is an `mrb_obj_class` comparison against a real class, not a `mrb_*_p`
  primitive check) -- purely a new diagnostic-only fact, `== known-array-
  element PRIMITIVE hints (informational only, never embedded) ==`, so a
  future code-reading round can immediately see "this is provably
  `Array<Integer>`, nothing to investigate" instead of re-deriving that
  by hand (exactly what the two parallel code-reading rounds preceding
  this one had to do for several of their own candidates, independently
  reaching the same "elements are plain Integer/Hash, no annotation
  mechanism exists for this" conclusion by manual inspection).

  `ArrayElementLayout.analyze`'s own `SETIV` sweep also gained the
  element-dimension counterpart of `ClassLayout`'s existing
  NIL_TOLERANT_JOIN (`@x = nil`, reusing the same `nil_literal_write?`
  helper): a plain `@ivar = nil` site is now skipped rather than treated
  as an opaque/poisoning site, matching how the ivar's own CLASS
  dimension has treated it since an earlier round.

  Verified via a real whole-program regen, isolated with a controlled
  `git stash` before/after (both runs through the same host `mrbc`): the
  **generated C++ output is byte-for-byte identical** before/after (this
  round is diagnostic-only, as designed -- primitive facts are never
  consumed, and the ANY/OPAQUE split is pure reporting over an unchanged
  join). Real effect isolated to the diagnostic: array-element candidates
  43 -> 36 (6 resolved to `Array<Hash>` PRIMITIVE hints --
  `Game::Map#@substitutions`/`@substitution_snapshot_cache`,
  `Game::State#@tile_substitutions`,
  `Game::Interpreter#@location_requests`/`@move_route_requests`/
  `@sprite_flash_requests`, all six independently identified as
  Hash-literal-element gaps by this session's own preceding code-reading
  round; 1 -- `Game::Interpreter#@choice_labels` -- correctly dropped to
  no entry at all, its only non-nil write site reaching an empty-literal
  origin through a MOVE-aliased register the existing scan already
  couldn't see past, an unrelated pre-existing precision gap, not a
  regression). `docs/bc2cpp_coverage.txt` also incidentally regenerates
  fresh against an **unrelated, pre-existing** staleness already present
  on `master` before this round touched anything (confirmed via the same
  stash-isolated check with bc2cpp.rb reverted alone: compiled entry
  points 1985 -> 1986, `unhandled opcode EXCEPT` 8 -> 7, #error total
  816 -> 815) -- not caused by this change, just carried along by the
  same regen. `bash scripts/bc2cpp_coverage_check.bash`: fresh.
  `scripts/rpg2k_logic_check.rb` (1201 checks), `scripts/
  rpg2k_scene_check.rb` (1062 checks), `scripts/lcf_testbed_check.rb` all
  still pass. Independently verified with a real `g++ -std=c++17
  -fsyntax-only` compile of the actual `SKIP_UNSUPPORTED=1` generated
  output: the same 6 pre-existing, unrelated `int` -> `mrb_value`
  conversion errors in `anim_target`/`command_item`, zero new ones.

  `HashElementLayout` (still in unmerged PR #1728 as of this round) does
  not yet have this same ANY/OPAQUE/primitive treatment -- a natural
  follow-up once it lands, since it shares the identical sticky-join
  shape this round modified twice already.
