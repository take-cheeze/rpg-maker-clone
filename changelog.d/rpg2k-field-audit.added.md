- **`scripts/rpg2k_field_audit.rb`** — a survey (not a check: it asserts nothing
  and always exits 0) of which database fields the real test beds *set* that the
  runtime never *reads*. For every scalar field it counts the rows set away from
  the schema default and reports the ones whose name appears nowhere in
  `mruby-rpg2k/mrblib`, ranked. Six of this runtime's RPG2000 decisions came out
  of asking that question by hand (ADRs 0031-0036), none of them visible to the
  fixture suites — in every case the fixtures encoded the same assumption as the
  code, because they were written to match it. Carries a `NOT_OURS` table of
  fields already checked against EasyRPG and deliberately left alone (`levitate`
  and `state_chance` are RPG2003 only, `message_affected` has no known trigger,
  the two critical-hit terms are unresolved), so nobody re-derives them.
