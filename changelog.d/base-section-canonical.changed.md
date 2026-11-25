- **bc2cpp base RBS** is deterministic: `base_section_check.rb --write` writes
  the base section of `sig/bc2cpp/declarations.rbs` (and nfcxx's
  `sig/base_core.rbs`) from the generators' output alone, in tag order, and the
  check now compares it byte for byte. The committed section is rewritten once
  into that order, which also adds the native blocks of eight gems the old
  writer could not append. `base_rbs_determinism_check.rb` reruns the
  generators under another locale, TZ, TMPDIR, path and worker count.
