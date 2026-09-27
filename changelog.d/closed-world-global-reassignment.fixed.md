- The closed-world lint now rejects global variables with multiple write sites
  across the compiled Ruby sources, preventing reassignment from invalidating
  whole-program facts.
