- **Vehicles:** A moving Boat/Ship now collides with a different parked
  Boat/Ship or a grounded Airship, and an Airship can no longer land on a
  parked Boat/Ship's tile, matching real RPG_RT — vehicle-vs-vehicle
  collision was never checked before, so a party riding a Boat could sail
  straight through a parked Ship, and a landing Airship could set down right
  on top of one. Covered by two new `scripts/rpg2k_scene_check.rb` checks.
