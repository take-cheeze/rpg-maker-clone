- **Wio Terminal**: drawing a map no longer allocates heap memory for each strip
  of tiles or pictures it composes; the rows are composed in buffers kept
  between frames.
