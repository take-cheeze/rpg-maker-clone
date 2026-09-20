- **bc2cpp** now checks exact container class identity before its indexed
  access fast paths, preserving subclass and singleton `[]`/`[]=` overrides.
