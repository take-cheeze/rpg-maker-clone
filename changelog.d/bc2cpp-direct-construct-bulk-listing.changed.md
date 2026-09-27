bc2cpp: list every class with a compiled #initialize for direct construct

Listing RPG2k::Window (the previous commit) was 168 sites in waiting; this
extends the same treatment to every class in the rpg2k gem that has a compiled
#initialize and is in the gem's ONLY_OWNERS -- 47 classes, derived from the
build's own "whole-program method registry" listing rather than hand-picked.

LISTING_GRANTS_NOTHING is the property that makes a list this broad safe. An
entry in DIRECT_CONSTRUCT_TARGETS only lets lexically_resolve_construct_target
CONSIDER the class. compile_send still re-checks all four gates on every run:
no custom self.new/self.allocate anywhere in the closed world, an #initialize
that compiles clean, the call count inside [mand, mand+opt] with the optional
jump table resolved, and the owner emitted. A class that fails any of them
keeps its dynamic dispatch, so listing a class that cannot fire costs nothing
but a line.

Two of those gates were added because the broader list exposed them, both
found by compiling the generated C++ rather than by the check suite:

  - NATIVE_ARG_TYPES_STAY_BOXED: RPG2k::Scene::Map::LRUBitmapCache#initialize
    carries `# bc2cpp: (fixnum)`, so its _impl takes mrb_int. The unboxing lives
    in the entry wrapper's mrb_get_args("i"), which a direct call bypasses, so
    the positional arm was a type error:
        RPG2k__Scene__Map__LRUBitmapCache_initialize_impl(M, r2, r3);
                                                       ^ cannot convert mrb_value to mrb_int
    Such a class now keeps dynamic dispatch rather than growing a second,
    separate unboxing proof.
  - (the keyword guard from the previous commit, for the same reason on
    RPG2k::Scene::Map and RPG2k::Scene::ChipsetEditor's keyworded #initialize.)

Measured on the hot-only wio closed world, full compilation, core mrblib in the
world, BC2CPP_NO_ONLY_OWNERS=1:

  POLY 2309 -> 2242, MONO 2081 -> 2148, TYPED 615 (unchanged)
  direct-construct `:new` sites 425 -> 500 across 23 firing classes
  object .text 3,935,247 -> 3,940,130 (BUILD OK)

and on the hot-only build that actually ships (BC2CPP_HOT_METHODS=1, the
215-method list): 34 block fallbacks, unchanged, generated C++ compiles.

The object is larger, which is the expected direction: a guarded direct call is
bigger than the single mrb_funcall it replaces. This whole line of work is a CPU
trade, not a flash one.

scripts/bc2cpp_*_check.rb: 44 pass, 5 fail -- the same 5 that fail at the commit
this branch started from.
