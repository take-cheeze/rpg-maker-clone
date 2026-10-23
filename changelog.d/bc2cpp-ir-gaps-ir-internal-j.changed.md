- **bc2cpp** the bytecode IR's own type, dataflow, class-body and constant
  passes read instructions through `Program#source_at` / `#each_source`
  instead of indexing `irep.instructions`. No analysis result changes.
