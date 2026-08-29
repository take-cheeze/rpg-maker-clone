- **Change Class (1008, RPG2003-only) now announces each skill it newly
  teaches, not just the level line**, closing the gap the Change Level /
  Change EXP skill-learned fix (`changelog.d/change-level-skill-learned.fixed.md`)
  deliberately left open. Ported from a reference implementation, not
  independently confirmed against genuine RPG_RT under wine: its own
  class-change code calls the identical learn-level-skills routine
  Change Level/Change EXP already use, which pushes
  a learning-announcement message for every
  growth-table skill the class swap teaches, skipping one the actor already
  knew (via that same routine's own already-learned guard). This
  codebase's `Game::Interpreter#do_change_class` (`mruby-rpg2k/mrblib/
  interpreter.rb`) already pushed a single level-up line when the class swap
  raised the level or changed the skill mode, but never named a single skill
  the change taught. Fixed by snapshotting each target's skill list
  immediately before `#change_class` runs (`before_skills`, the same idiom
  `queue_level_up_messages` already uses) and appending one
  `skill_learned_message` line per post-change skill absent from that
  snapshot onto the same page as the level-up line. The show-message trigger
  itself is also more precise now: it fires on an actual skill diff being
  non-empty rather than guessing from the skill mode alone, so a
  RESET/ADD class swap that happens to teach nothing the actor didn't
  already know stays quiet, same as a level that didn't move. Covered by two
  new `scripts/rpg2k_logic_check.rb` checks (a class swap whose learn table
  teaches two skills across levels 1 and 3 names both on the level-up page; a
  skill taught early via an explicit Change Skills stays quiet, naming only
  the genuinely new one), both confirmed to fail against the pre-fix code
  before the fix.
