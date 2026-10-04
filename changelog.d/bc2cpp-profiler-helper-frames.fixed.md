- **bc2cpp** keeps Profiler captures separate from block-local registers, preserves
  captured writes and nested frame offsets, and routes nonlocal returns through
  the existing method-return fallback.
