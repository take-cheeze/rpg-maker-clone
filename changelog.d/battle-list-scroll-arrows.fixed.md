- The in-battle **Skill** and **Item** lists now draw RPG2000's two blinking
  windowskin scroll arrows when they hold more rows than the four-row box
  shows, and keep the scroll offset the way RPG_RT does. Measured against a
  genuine `RPG_RT.exe` under wine: the arrows are the 16x8 windowskin cells
  blitted centred on the list window's own top and bottom frame borders
  (logical (152, 160) and (152, 232)), the up one shown only while a row is
  hidden above and the down one only while a row is hidden below, both
  blinking together 20 frames on / 20 off (a 0.6667s period timed at 60fps
  over 17 cycles — the first time that period was measured on a list rather
  than inherited from the message window's pause arrow). The scroll offset is
  **sticky**: a list that has scrolled keeps its top row and moves by the
  smallest amount that keeps the cursor visible, so stepping back up inside
  the box no longer scrolls the box back, and the offset survives Decision
  into target selection. The shared arrow drawing, blink and sticky-scroll
  rule moved onto `Scene::Base`, which the field Item and Skill grids now use
  too.
