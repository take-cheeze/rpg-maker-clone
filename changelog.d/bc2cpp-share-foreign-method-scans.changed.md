- **bc2cpp** reuses per-file foreign Ruby method-name scans in closed-world
  definer queries, avoiding repeated AST walks and regex scans for each name.
