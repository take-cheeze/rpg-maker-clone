bc2cpp: call-site CLASS inference, so a class annotation can be checked

The fixnum/symbol half of RBS_SEED_CONTRADICTION could compare an annotation
against ArgTypes' independent proof. The class-name half could not, because no
such proof existed: ClassAnnotations was consumed ONLY as a SEED into
ClassLayout's fixed point, so a wrong class annotation silently became the fact
it seeded. Verified by injecting `# bc2cpp: (Game::Actor, )` on
LCF::Array1D#initialize (whose position 1 is a String) -- the run completed and
reported nothing.

ClassArgTypes is ArgTypes' idea applied to the class lattice: for a MONO name
every call site reaches the one definition, so if every caller's argument at
position k traces to a class, position k is that class. It uses trace_new_target
and resolves 38 (name, position) pairs across 37 names on the real hot-only wio
closed world -- 17 Array, 8 RGSS::Bitmap, 3 Hash, 3 Game::MoveRoute, 2 Rect, and
one each of Tone, RPG2k::Scene::Map, LCF::SaveData, Game::Troop, Game::Enemy.

Three things it deliberately does NOT do, each of which was a wrong answer
first:

  * it does not report a class where it has no evidence. A nil means "no fact" --
    a call site whose receiver is unknown, or a slot nothing resolved. Never
    "some other class". Same rule the :nil_literal case in the contradiction
    check turned on.
  * it does not pick a winner between two call sites passing DIFFERENT classes.
    That is genuine heterogeneity, and ClassLayout's join collapses
    disagreement to UNKNOWN for a load-bearing reason (docs/adr/0139 wrongly
    embedded ivars in Game::Screen and Game::State when an UNKNOWN was dropped
    because a concrete type arrived first). Such a slot records nil.
  * it is NOT fed into ClassLayout or IvarLayout. Growing a fixed point's inputs
    would invalidate the order-independence argument ADR 0139 is written about,
    for no proven benefit. Its only consumer is the contradiction check, and a
    new "call-site CLASS inference (MONO names only)" diagnostic.

TWO_HASH_MUTATION_BUGS, both found by the check suite rather than by reading:
the tracer indexes two tables that are built with `Hash.new { |h, k| ... }`
defaults, so a read on a miss INSERTS. Passing the live `class_layout` and
`registry` therefore mutated a caller's table mid-iteration, and
bc2cpp_never_called_registrations_check.rb -- which walks the registry -- died
with "can't add a new key into hash during iteration" (registry.rb:95). The
chained-accessor arm's `registry[name]&.find` is the subtle one, because `&.`
still evaluates the default. This analysis now works on its own
default-proc-free copies at both levels and mutates nothing the caller owns.

Verified on the real hot-only wio closed world, full compilation, core mrblib,
BC2CPP_NO_ONLY_OWNERS=1: the generated C++ is byte-identical to the previous
commit (object .text 3,940,130, BUILD OK) -- the table is a reporting/checking
artifact only -- and the contradiction check still reports `(none)`.

scripts/bc2cpp_*_check.rb: 46 pass, 5 fail -- the same 5 that fail at the commit
this branch started from.
scripts/bc2cpp_class_arg_types_check.rb covers the four guards above.
