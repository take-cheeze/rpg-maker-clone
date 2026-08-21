- **Events:** a Flash Sprite command with its wait flag set now blocks the
  event even when its own duration is 0.0 seconds, matching RPG_RT --
  previously a zero-duration flash applied instantly and the wait was
  skipped outright.
