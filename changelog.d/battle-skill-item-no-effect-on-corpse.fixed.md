- **A status-curing or SP-restoring item/skill no longer affects a downed
  ally it does not also revive.** `Game::Battle#apply_skill_hit`'s recovery
  branch could still clear a non-death status, or restore MP, on an
  already-dead target as long as some cure/restore was queued — even though
  the same hit's HP heal was already correctly skipped. An ordinary Skill
  can't reach this with a dead target unless it cures Death in the first
  place, but an Item's own target is always valid regardless of the
  target's state, so a status-curing or SP-restoring item used on a downed
  ally could still reach here without reviving it. The cured-states loop and
  the MP write are now both skipped whenever the target was already dead and
  this same hit does not also cure Death, matching the HP write's existing
  behavior.
