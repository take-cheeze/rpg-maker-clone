- **CI:** run 197 bc2cpp fixture checks in three independent jobs alongside the closed-engine
  build and game sweep. Preserve the command list, four workers per shard, failure propagation,
  and the required aggregate gate; keep closed-artifact checks with the engine build.
