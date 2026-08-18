- **Map events:** A cascade of several no-Wait Auto-Start events finishing
  within the same real frame now shares one combined 10000-command step
  budget for that frame, matching real RPG_RT — each cascaded event used to
  get its own fresh 10000-step budget, so a chain of N heavy Auto-Start
  events could burn up to `N * 10000` steps in a single frame instead of
  spilling the excess into later frames like a lone heavy event already did.
  Each Parallel Process keeps its own independent budget, unaffected. Covered
  by a new `scripts/rpg2k_scene_check.rb` check.
