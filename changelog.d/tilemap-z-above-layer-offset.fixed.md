- Fixed a real gap in `mruby-rgss`: reassigning a native `Tilemap`'s `z`
  (e.g. a script moving the tilemap behind/above some other z-managed
  object) never moved its priority "above" layer along with it. The above
  layer is a second, internal LVGL canvas holding priority-tile pixels
  (roofs, tree crowns) so they sort over the character sprites; its own `z`
  used to be set once at construction and never touched again, so a script
  that ever reassigned `tilemap.z` broke the "above sorts higher than the
  tilemap itself" relationship the two layers are supposed to keep in
  lockstep -- only the ground canvas actually moved. `Tilemap#z=` now keeps
  the above layer pinned a fixed offset above the tilemap's own `z`, the
  same propagation `Tilemap#visible=` already had to learn for visibility.
