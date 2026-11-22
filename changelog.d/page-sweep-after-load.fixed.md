- **Event pages flip again after loading a save.** Loading replaces the switch
  and variable tables, and the map's page sweep then skipped every later sweep
  until the party or a timer changed, so a switch an event flipped did not
  change any page. The sweep also no longer runs, and allocates, on frames
  where nothing it reads changed.
