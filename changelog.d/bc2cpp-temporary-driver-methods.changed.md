- **bc2cpp:** remove temporary iterator and resumable driver method-table entries after rooting
  their Procs, removing 41 entries from the closed build. Repeated registration reuses saved iterator drivers, and resumable calls execute
  their saved driver without a method-name lookup.
