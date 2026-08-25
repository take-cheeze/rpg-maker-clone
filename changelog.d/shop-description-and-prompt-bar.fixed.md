- **Shop screen:** now matches RPG_RT's real layout — a full-width bar at
  the very top shows the highlighted good's own database description, and
  the shopkeeper's own prompt/greeting line is drawn as its own fixed panel
  at the screen's bottom message slot rather than merged into the goods
  list's first row. The goods list itself now docks directly under the
  description bar with a fixed minimum height, instead of floating
  bottom-anchored and sized to its own row count. Previously no description
  bar was drawn at all, and the shopkeeper's line lived inside the list
  window, both never verified against a real capture.
