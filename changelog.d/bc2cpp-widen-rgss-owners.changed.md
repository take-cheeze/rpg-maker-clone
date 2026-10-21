- **bc2cpp** RGSS native wrapper owner tables are now derived from the generated
  `NativeDirect::ENTRIES` table. The closed-world build gains `RGSS::Tilemap` as
  an owner of `update`, so `Tilemap#update` call sites take the direct
  `tilemap_update_direct` wrapper instead of the generic guarded chain. The
  `visible`, `tone=` and `opacity=` owners the generated table adds (`Tilemap`,
  `Window`, `Plane`) emit no change in the closed build. `bitmap=` stays out of
  the wrapper tables, and the six multi-arity wrappers keep their hand-listed
  owners.
