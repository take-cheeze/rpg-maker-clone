- **Event interpreter restarts allocate less.** Starting an event run empties the
  interpreter's queues in place, and draining an empty request queue no longer
  makes a new array. A looping parallel event used to make 8 to 11 arrays per
  frame this way.
