- **Vehicles now play their own BGM.** Boarding a boat / ship / airship switches
  to the vehicle's database System music (`boat_music` / `ship_music` /
  `airship_music`), remembering the BGM that was playing; stepping off restores
  it, so the map's music resumes. A vehicle with no configured BGM leaves the
  current music playing. Covered by a new check in `scripts/rpg2k_scene_check.rb`
  (boarding a boat plays the boat BGM and disembarking brings the map BGM back).
