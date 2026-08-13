- **A ridden boat/ship/airship now walk-cycles with the party** instead of
  always drawing its standing pose. The vehicle sprite already tracked the
  party's own pixel position frame for frame while boarded, but
  `Scene::Map#draw_vehicle_frame` hard-coded the CharSet pattern to 1
  (standing) regardless — so a sailing boat glided across the water with a
  frozen paddle. It now reuses the hero's own walk-cycle pattern
  (`#player_walk_pattern`, factored out of `#draw_player_frame`) whenever the
  vehicle is ridden, since a boarded vehicle slides in lockstep with the
  party and so animates on the identical schedule the hero's own sprite
  would have shown were it not hidden underneath the vehicle's. An unridden
  vehicle still holds its standing pose — it snaps tile to tile rather than
  sliding (per the Move Event / Set Move Route vehicle work), so there is no
  in-tile progress to animate against; that remains a follow-up.
