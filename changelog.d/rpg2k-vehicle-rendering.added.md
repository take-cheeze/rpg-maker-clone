- **Vehicles are drawn on the map.** Each vehicle placed on the current map now
  renders as a sprite from its CharSet (its own graphic, set by Change Vehicle
  Graphic / the initial placement, or the database System boat / ship / airship
  default), positioned camera-relative on its tile. A parked vehicle sits on its
  own tile; the **ridden** vehicle follows the party's pixel position (so it
  slides smoothly) and is drawn just under the hero, so a boarded party rides on
  top. A vehicle on another map, or one with no CharSet, is hidden. The vehicle's
  own BGM and the airship's ground shadow are still to come. Covered by new checks
  in `scripts/rpg2k_scene_check.rb` (a placed vehicle is drawn while an unplaced /
  off-map one is not; the ridden vehicle tracks the party and sits beneath the
  hero).
