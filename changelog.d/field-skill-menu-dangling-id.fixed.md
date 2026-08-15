- **The field skill menu no longer drops a dangling learned-skill id with no
  trace** — a database shrink can leave a caster's learned skill id pointing
  at nothing, shown as "?" in the editor. `Game::Party#field_skills`
  (`mruby-rpg2k/mrblib/game.rb`) now logs a `[RPG2k] Skill menu: caster's
  learned skill #<id> has no matching database row, excluding from field
  menu` diagnostic instead of silently omitting it. The skill still doesn't
  appear in the menu — there's nothing sensible to show for it — this is
  diagnostics only. Covered by a new `scripts/rpg2k_logic_check.rb` check.
