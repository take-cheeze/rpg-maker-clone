- An RPG2000 map event's own Parallel Process now keeps running to
  completion once its owning event's appearance conditions stop being
  satisfied mid-script, instead of being silently torn down. `#build_events`
  already drops such an event from `@events`/`@event_tiles` entirely once no
  page's conditions match, and `#build_parallels`'s bystander-preservation
  pass only ever looked for a still-running Parallel Process among the
  events that pass survived into `@events` -- so a process that flipped off
  its own gating switch, or was otherwise hidden by an unrelated write mid-
  run, vanished the instant the next page-reselection sweep ran, rather than
  finishing out its script the way real RPG_RT does.
