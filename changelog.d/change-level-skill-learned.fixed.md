- **Change Level / Change EXP now announce a learned skill alongside the
  level that teaches it**, matching real RPG_RT. Confirmed against genuine
  RPG_RT.exe under wine: a synthetic autostart Change Level on Nepheshel's
  own actor 2 (ファル, level 1), +1 level (no skill scheduled at level 2),
  showed a single-line message box reading "ファルはレベル２になった！"; the
  identical setup with +2 levels instead (crossing level 3, which the
  database's own actor-skill table teaches a skill at) showed a two-line box
  in the same window, the level line immediately followed by "バマーも覚え
  た！" — one line per skill, appended onto the same page as the level-up
  line rather than a separate page/box. This codebase's
  `Game::Interpreter#queue_level_up_messages` (`mruby-rpg2k/mrblib/
  interpreter.rb`) already queued the level-up line itself but never
  consulted the growth table at all, so a skill a party member gained by
  levelling up silently joined their skill list with no announcement,
  regardless of how the level was granted (Change Level, Change EXP, or a
  battle victory's own EXP award, which reaches the same command path).
  Fixed by snapshotting each target's skill list immediately before the
  change (`before_skills`) and, for every level actually gained, appending
  one line per growth-table skill scheduled at that exact level and absent
  from the snapshot onto that level's own message page — a skill already
  known going in (an earlier explicit Change Skill teach) stays silent, the
  same distinction EasyRPG's `IsSkillLearned` check makes. Change Class
  (1008, RPG2003-only) shares the same underlying gap — EasyRPG's
  `Game_Actor::ChangeClass` calls the identical `LearnLevelSkills(1,
  new_level, pm)` — but is left unaddressed here; see `docs/TODO.md`.
  Covered by two new `scripts/rpg2k_logic_check.rb` checks (a two-level
  Change Level crossing two learn-table thresholds announces each skill on
  its own level's page; a skill taught early via Change Skills stays quiet
  when the level that would have taught it is later reached), the first
  confirmed to fail against the pre-fix code before the fix.
