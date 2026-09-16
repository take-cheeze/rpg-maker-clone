- `tools/bc2cpp/bc2cpp.rb`'s `HashElementLayout` (the Hash-value analogue
  of `ArrayElementLayout`) now gets the exact same three-part treatment
  `ArrayElementLayout` gained in a preceding round -- this is the "natural
  follow-up once it lands" that round's own changelog flagged, now that
  `HashElementLayout` is on `master`:
  - **ANY vs. OPAQUE split**: `HashElementLayout.analyze` gains the same
    optional `poison_reason:` keyword (a caller-supplied Hash filled in
    as a side effect on each ivar's first poisoning transition, default
    `nil` for zero behavior change) and a new `.unknowns_by_reason`
    filter, reported as two new, purely additive diagnostic sections
    (`== hash-element candidates split: ANY/OPAQUE ==`). Whole-program
    result: **zero** `ANY` entries here either -- every poisoned
    `HASH_ELEM_CANDIDATE` today is `OPAQUE` (an untraced site), never a
    proven two-site conflict.
  - **Primitive value types**: `.known` now also excludes a
    `PRIMITIVE_ELEMENT_CLASSES` tag (the same constant `element_value_class`
    already produces for a literal `Integer`/`Hash`/`String`/`Symbol`
    value -- no new terminal cases were needed, that function was already
    fully generic), reported in a new `== known-hash-element PRIMITIVE
    hints (informational only, never embedded) ==` section via the new
    `HashElementLayout.primitives`.
  - **Nil-tolerant SETIV**: `HashElementLayout.analyze`'s own `SETIV` arm
    gained the value-dimension counterpart of `ArrayElementLayout`'s own
    nil-tolerant fix, reusing the same `nil_literal_write?` helper -- a
    plain `@h = nil` site (a cache-invalidation idiom) no longer poisons
    an otherwise-uniform Hash ivar.

  Verified via a real whole-program regen, isolated with `git stash`:
  generated C++ output is **byte-for-byte identical** before/after (same
  story as `HashElementLayout`'s own original round -- these are proven,
  wired, zero-regression facts, not yet consumed by any real call site in
  today's program). Real diagnostic effect: the nil-tolerant fix alone
  resolved 2 real ivars that were previously poisoned purely by a
  cache-invalidation `= nil` site -- `RPG2k::Scene::Map#@inn_window` and
  `RPG2k::Scene::Menu#@message`, both now `Hash<RPG2k::Window>`
  (`HASH_ELEM_HINT` 8 -> 10, poisoned `HASH_ELEM_CANDIDATE` 38 -> 36).
  Zero primitive-typed Hash values found in the program today (the
  `PRIMITIVE hints` section is empty) -- unlike the Array side, no real
  `Hash#[]=`/`.store` write site in this codebase happens to push a
  literal Integer/Hash/String/Symbol value directly; a real, legitimate
  "nothing to report" outcome, not a bug.
  `bash scripts/bc2cpp_coverage_check.bash`: fresh. `scripts/
  rpg2k_logic_check.rb` (1201 checks), `scripts/rpg2k_scene_check.rb`
  (1062 checks), `scripts/lcf_testbed_check.rb` all still pass.
  Independently verified with a real `g++ -std=c++17 -fsyntax-only`
  compile of the actual `SKIP_UNSUPPORTED=1` generated output: the same 6
  pre-existing, unrelated `int` -> `mrb_value` conversion errors in
  `anim_target`/`command_item`, zero new ones.
