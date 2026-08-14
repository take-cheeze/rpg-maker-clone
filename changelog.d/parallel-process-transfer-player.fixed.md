- **Map events:** a Common Event Parallel Process's own Transfer Player
  command now actually warps the party, instead of silently doing nothing.
  `Scene::Map#drive_parallel_wait` had no case for the `:teleport` wait kind
  `Game::Interpreter#do_teleport` raises, so it fell into the generic
  "background: ignore message/choice/teleport requests" branch and just
  resumed the interpreter without ever calling `#perform_teleport` — the
  same command issued from the foreground (an Autorun) already worked. The
  same Parallel Process interpreter now keeps running on the destination map
  afterward, matching how it already survives a save/load or an ordinary
  Transfer Player from elsewhere. Covered by a new
  `scripts/rpg2k_scene_check.rb` check, confirmed to fail against the
  pre-fix code.
