- **Audio:** Play BGM / Play Memorized BGM now restart a track that was
  faded out by Fade Out BGM, even when it's the same file -- matching
  RPG_RT's `music_stopping` flag -- previously a same-name replay right
  after a fade-out silently resumed the fade's leftover volume instead of
  restarting from the top, unlike an ordinary same-file replay with no
  intervening fade.
