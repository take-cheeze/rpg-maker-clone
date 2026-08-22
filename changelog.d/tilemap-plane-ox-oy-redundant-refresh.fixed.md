- Fixed `Tilemap#ox=`/`#oy=` and `Plane#ox=`/`#oy=` re-compositing the whole
  visible tile grid or fog layer on every single frame, even when the camera
  did not move -- real RGSS treats these as cheap draw-time offsets, since
  stock `Spriteset_Map#update` reassigns them unconditionally every frame.
  Found because a real VX Ace game hung for minutes on a stationary camera
  before drawing its first frame. Fixed by skipping the re-composite when the
  new value equals the one already stored.
