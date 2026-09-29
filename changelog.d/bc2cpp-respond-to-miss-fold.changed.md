- bc2cpp: when no `respond_to_missing?` exists in the closed world, the miss path of the native
  `respond_to?` primitive is `false` instead of a real `respond_to?` send (191 fewer dynamic sends).
