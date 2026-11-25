- **A map visit keeps records only for the auto-start and parallel common
  events.** A called-only common event's record is made on its first Call
  Event. On Nepheshel (505 common events, 455 of them called-only) this frees
  about 29 KB of heap on every map.
