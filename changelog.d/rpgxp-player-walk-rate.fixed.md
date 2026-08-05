- The RPG Maker XP player's walk cycle runs at the real runtime's rate. Its
  frame was keyed off the distance walked — `(@move_count / 8) % 4` — which ran
  all four frames of the walk row inside a single tile, roughly three times too
  fast. It now uses the animation counter every other character uses (1.5 ticks
  a frame, a new frame every `18 - move_speed * 2` ticks) and returns to the
  standing frame once the player stops. Finishing a step also starts the next
  one in the same frame, so holding a direction no longer inserts a standing
  frame at every tile boundary.
