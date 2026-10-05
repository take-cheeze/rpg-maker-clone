- **bc2cpp** proves literal and `*rest` receivers exact inside compiled mruby
  core bodies too (ADR 0359), removing 40 by-name sends from the Wio build;
  `BC2CPP_CORE_BODY_EXACT=0` turns it off.
