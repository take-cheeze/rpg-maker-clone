- **The field/battle Item menus no longer drop a dangling held-item id with
  no trace** — a database shrink can leave a party-held item id pointing at
  nothing, shown as "?" in the editor. `Game::Party#field_usable?`/
  `#battle_usable?` (`mruby-rpg2k/mrblib/game.rb`) now each log a `[RPG2k]
  Item menu: party-held item #<id> has no matching database row, excluding
  from field menu` (or `..., excluding from battle menu`) diagnostic instead
  of silently omitting it. The item still doesn't appear in either menu —
  there's nothing sensible to show for it — this is diagnostics only.
  Covered by a new `scripts/rpg2k_logic_check.rb` check.
