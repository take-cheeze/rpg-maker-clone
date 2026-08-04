- **AGENTS.md** now documents a conflict-resolution rule for agents: when a
  branch or PR has merge conflicts against `master`, resolve them (merge or
  rebase the latest `master`, fix the files, re-run checks, and push) instead of
  leaving them, asking only when a conflict is genuinely ambiguous.
