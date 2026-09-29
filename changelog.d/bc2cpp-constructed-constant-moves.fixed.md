- bc2cpp now preserves constructed constant class hints when a `Klass.new`
  result passes through plain register copies before `SETCONST`.
