- The bc2cpp review gates (NOMETHOD, PROVEN_MISS, STRICT_HINT and the TC1017 constant ratchet) read a
  `# bc2cpp-reviewed: <gate> <spec> -- reason` comment on a site's source line instead of the central
  `*_REVIEWED` lists, which are removed along with their update scripts. Stale annotations fail
  `scripts/bc2cpp/source_review_check.rb` on a full run (ADR 0522).
