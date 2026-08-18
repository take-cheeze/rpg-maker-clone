- **RPG2003 actors:** An actor's database-declared *starting* class (chunk
  11 field 57) no longer takes effect on its own — matching RPG_RT, which
  keeps reading the actor's own row for its growth curve, EXP curve, learn
  table, battle-command list, 強力防御, 強制AI, 二刀流 and 装備固定 until an
  actual Change Class event runs. Previously all of these silently drew
  from the class the moment the actor was built, well before any Change
  Class command fired — a common RPG2003 authoring pattern (skipping an
  explicit Change Class at party-join time) meant every affected actor's
  stats, EXP thresholds, skills and traits were wrong from the very first
  frame. Covered by four new/corrected `scripts/rpg2k_logic_check.rb`
  checks.
