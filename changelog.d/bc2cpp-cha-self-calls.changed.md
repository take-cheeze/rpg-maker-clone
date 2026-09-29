- **bc2cpp resolves calls on `self` by class hierarchy analysis.** A call on
  `self` in a class with subclasses is now a direct `_impl` call, with no class
  compare and no dispatching fallback, when the closed world proves every
  descendant resolves the name to the same definition; when a few descendants
  override it, only they get exact-class arms and everything else calls the
  inherited definition. Self-receiver `bc2cpp_send` sites in the shipped wio
  build go from 688 to 213 and 253 `NOMETHOD_REVIEWED` entries become stale and
  are removed. `BC2CPP_CHA_REPORT` and `scripts/bc2cpp_cha_self_report.rb`
  report the eligibility per site. See
  `docs/adr/0254-bc2cpp-class-hierarchy-analysis-for-self-calls.md`.
