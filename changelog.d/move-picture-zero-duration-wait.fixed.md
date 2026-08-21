- **Pictures:** a Move Picture command with its wait flag set now blocks for
  one frame even when its own duration is 0.0 seconds, matching RPG_RT --
  previously a zero-duration move applied instantly and the wait was
  skipped outright.
