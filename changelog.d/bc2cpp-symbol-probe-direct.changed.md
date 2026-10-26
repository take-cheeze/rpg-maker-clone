- **bc2cpp**: `respond_to?` with a proven Symbol name calls the audited Kernel
  body without a redundant Symbol type test or dispatch fallback. Overrides,
  missing-method hooks and BasicObject receiver checks retain their safeguards.
