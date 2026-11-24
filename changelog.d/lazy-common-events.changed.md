- **Common events load on demand**: a map no longer holds every common event's
  database row, nor the command list of an auto-start common event whose switch
  is off; a list is read the first time it can run. On Nepheshel this frees
  about 390 KB of heap on every map. A host that defines
  `RPG2K_EAGER_COMMON_EVENTS` true loads them as before.
