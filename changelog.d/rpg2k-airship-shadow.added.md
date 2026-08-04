- **The airship now casts a ground shadow.** When the airship is on the current
  map it is drawn floating a few pixels above a translucent shadow blob on its
  ground tile (the shadow under the vehicles, over the ground / events), selling
  its altitude the way RPG_RT does. Boats and ships — which sit on the water — get
  no shadow. Covered by a new check in `scripts/rpg2k_scene_check.rb` (the airship
  floats above a visible shadow that sits beneath it; a boat casts none).
