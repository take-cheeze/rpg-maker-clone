- The map-walk port (iPod nano 7G and Wio Terminal) draws the **player's own
  CharSet sprite** instead of a plain marker: the project's initial party
  leader, walking RPG2000's own cycle and turning to face a bump the same way
  the genuine renderer does, even when the step itself is blocked. The export
  asks `Game::CharSet` for the frame geometry and walk pattern rather than
  restating them, so a project with no static leader (a runtime Change Sprite
  Association, say) simply exports without one — the marker's old behaviour,
  unchanged. Costs 248 bytes of device code and a fixed 10.5 KB of RAM,
  reserved whether or not a given export actually carries a hero. Format
  version 6: re-export before installing. See ADR 96.
