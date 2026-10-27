- **bc2cpp**: the SHARED_GENERATION environment guard, armed for the whole analysis that runs before the per-gem
  fork, tests `ENV[]`, `ENV.fetch` and `ENV.key?` against the unit keys without allocating. Its generic form had
  put about a tenth of `compute_numeric_facts` into the guard; the rpg2k generation replay drops about 9 s of
  CPU (roughly 6%, four paired runs), with byte-identical output. A unit key read before the fork still fails
  the run with the same error.
