- **Move routes / move types:** an event facing or moving toward/away from
  its target (Move Route Face/Move Toward Hero / Away From Hero, Move Type
  "Approach Player" / "Away from Player") now resolves an exact horizontal/
  vertical tie the same way RPG_RT does -- vertically, landing on Down --
  instead of the horizontal axis. An event already standing on its target's
  tile now also turns to face Down like real RPG_RT, instead of keeping
  whatever direction it last faced. Matches `Game_Character::
  GetDirectionToCharacter`'s strict `>` comparison, which falls to the
  vertical branch (and its `sy == 0` -> Down default) on any tie including
  the same-tile case.
