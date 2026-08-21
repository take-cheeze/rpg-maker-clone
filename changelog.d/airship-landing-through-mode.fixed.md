- **Vehicles:** an event with Through Mode on no longer lets the airship
  land on its tile -- matching RPG_RT's own `CanLandAirship`, which blocks
  a landing on any active event's tile unconditionally and never reads
  Through Mode at all, unlike a boat/ship's own movement collision.
