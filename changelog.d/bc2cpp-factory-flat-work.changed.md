- **bc2cpp** factory use walks traverse with a flat work stack and per-origin
  visited sets instead of per-state pair Arrays, preserving LIFO order, result
  order and alias-budget refusal.
