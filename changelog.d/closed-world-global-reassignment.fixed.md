- The closed-world lint now rejects global variables with multiple write sites
  or writes in repeatable contexts, preventing reassignment from invalidating
  whole-program facts.
