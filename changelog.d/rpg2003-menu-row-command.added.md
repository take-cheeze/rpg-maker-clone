- **RPG2003's field-menu Row command** (`menu_commands` id 6) is implemented:
  picking it hands focus to the party-status panel like Skill/Equipment/
  Status, and confirming an actor toggles their front/back row in place
  (`Game::Party#toggle_actor_row`) with no sub-scene opened, refusing to
  leave the whole party in the back row the way real RPG_RT does.
