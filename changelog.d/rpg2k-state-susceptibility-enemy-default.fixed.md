- **A state id past the end of a battler's own susceptibility-rank array now
  defaults to the correct rank per side — B/80% for an enemy, C/60% for an
  actor — instead of always C/60%.** Ported from a reference implementation,
  not independently confirmed against genuine RPG_RT under wine: the actor
  and enemy susceptibility lookups there are two distinct functions with two
  distinct defaults, not one shared default. Any enemy whose database row's
  `state_ranks` array doesn't cover a particular state — a routine
  situation, since the LCF format truncates trailing default-valued bytes
  — was landing that state at 60% of a skill's own chance instead of the
  real 80%.
