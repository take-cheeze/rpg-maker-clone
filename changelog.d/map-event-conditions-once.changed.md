- A map reads its events' page conditions once per visit. Checking whether an
  event's page changed no longer reads the map's event rows every frame, and
  events with equal conditions share one record.
