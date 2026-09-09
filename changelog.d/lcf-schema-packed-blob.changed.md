- **`mruby-lcf`'s schema data (`mrblib/schema.rb`) now ships as a compact
  packed binary blob plus a small decoder, not ~1,150 Hash-literal-
  construction bytecode sequences** — real, measured cut on a full relink
  (`env:wio_rgss_boot`): 15,624 bytes. Verified byte-for-byte behaviorally
  identical to the original schema (every constant, every nested/lazy
  field, every default, both real object-identity-sharing cases) except one
  intentional drop: `enums:` metadata, confirmed dead (never read anywhere
  in the codebase). `mrblib/schema.rb` itself is untouched and stays the
  single source of truth every check script still loads directly — only
  the compiled mruby build's own copy changed. See ADR 109.
