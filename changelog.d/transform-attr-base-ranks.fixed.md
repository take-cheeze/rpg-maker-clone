- **A transformed monster's later attribute-defence shifts now cap against
  its new form's own resistance, not the pre-transform monster's.**
  `#enemy_transform_action` updated the monster's current attribute ranks on
  Transform but left the snapshotted "base" a later shift is capped +-1
  around still pointing at the original form.
