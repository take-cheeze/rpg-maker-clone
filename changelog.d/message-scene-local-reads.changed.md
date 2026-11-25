- The map scene's message driving reads its message state once per frame
  into a local. The compiled code keeps one nil test per method instead of
  one per read, and Wio flash shrinks.
