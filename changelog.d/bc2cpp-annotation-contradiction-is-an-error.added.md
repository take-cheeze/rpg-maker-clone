bc2cpp: an annotation that contradicts a proved type is a build error

Spinel's rule for an RBS signature it can represent is that it "is an assertion,
not a hint": a contradiction the compiler can see is a compile error, and one
that only turns out wrong at run time "is reinterpreted rather than widened".

bc2pp already had the seeding mechanism -- `# bc2cpp: (T, ...) -> R`, read by
Annotations and ClassAnnotations -- but it only ever ADDED a fact. An annotation
that disagreed with an inferred fact was indistinguishable from one that merely
failed to apply, so a typo in a hand-written annotation cost an optimization in
silence. This adds the missing half.

The rule is narrow, because it has to be sound and cheap. Only :fixnum and
:symbol are comparable, and a contradiction is only :fixnum against :symbol or
the reverse. Everything else is an ABSENT comparable fact, not a conflicting one:

  * :nil_literal does not contradict.
    RPG2k::Scene::Battle#battle_level_up_lines annotates `before_level` as
    fixnum, and its one call site is guarded (`... if before_level`), so
    ArgTypes proves :nil_literal. Both statements are true -- the annotation is a
    claim about the non-nil case, and the guard is what makes it true. The first
    version of this check refused it, and refusing would refuse a correct
    annotation of the shape annotations most often take.
  * a class name does not contradict. ClassAnnotations is a different lattice
    with no shared representation, so comparing the two would invent a
    disagreement rather than find one.
  * UNKNOWN and an unrepresented type do not contradict.

`inferred_rets` is a Set of names proven Fixnum-returning, not a name -> type
table, so a member is a proof of :fixnum and a non-member is an absence.

Verified both ways on the real hot-only wio closed world:

  * clean tree: `== annotation/proof contradictions (RBS_SEED_CONTRADICTION) ==`
    reports `(none)`, and the generated C++ is byte-identical to the previous
    commit (object .text 3,940,130, BUILD OK) -- the check only reads tables the
    driver already had.
  * injected `# bc2cpp: (symbol)` on RGSS::Audio.singleton#bgm_volume, whose
    position 1 ArgTypes proves :fixnum: the run aborts with
    `CONTRADICTION RGSS::Audio.singleton#bgm_volume position 1: annotation says
    :symbol, inference proved :fixnum`.

scripts/bc2cpp_annotation_contradiction_check.rb covers the rule, including both
non-contradiction cases that the real tree exercised.

This is worth having on its own terms: this session shipped two build breaks that
the check suite called green, so a mechanism that turns a silently-wrong
hand-written fact into a failed build is worth more than another
devirtualization.

scripts/bc2cpp_*_check.rb: 45 pass, 5 fail -- the same 5 that fail at the commit
this branch started from.
