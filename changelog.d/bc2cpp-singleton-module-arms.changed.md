- **bc2cpp** guard chains now give a module's singleton definer (`Graphics.width`,
  `Graphics.height`) an identity-guarded direct arm, so 81 by-name `width`/`height`
  sends in the wio build end in a NoMethodError instead (ADR 0369).
