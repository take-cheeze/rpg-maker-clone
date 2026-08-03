# Changelog fragments

To avoid merge conflicts, **do not edit the `## [Unreleased]` section of
`CHANGELOG.md` by hand.** Every branch that edited that one section touched the
same lines, so every pull request collided.

Instead, each change gets its own file in this directory. Two branches never
touch the same file, so the fragments merge cleanly. The fragments are folded
into `CHANGELOG.md` at release time by `scripts/build_changelog.rb`.

## Adding an entry

Create one file per change, named `<slug>.<category>.md`:

```
changelog.d/control-variables-operands.added.md
changelog.d/lmt-scrollbar-signed.fixed.md
```

- `<slug>` — a short, unique, kebab-case description. Anything unique works;
  the issue/PR number (`118.added.md`) or a topic slug both avoid collisions.
- `<category>` — one of: `added`, `changed`, `deprecated`, `removed`,
  `fixed`, `security` (matching the "Keep a Changelog" sections).

The file body is the Markdown bullet(s) exactly as they should appear in the
changelog, starting with `- `. Wrapped continuation lines are indented two
spaces, like the rest of `CHANGELOG.md`:

```markdown
- **Control Variables** now supports random integers, actor stats and game
  quantities as operand sources. Covered by new checks in
  `scripts/rpg2k_logic_check.rb`.
```

## Handy commands

```bash
ruby scripts/build_changelog.rb list        # list pending fragments
ruby scripts/build_changelog.rb preview     # preview the merged Unreleased section
ruby scripts/build_changelog.rb release 1.2.0   # fold fragments into CHANGELOG.md
```

`release` renames `## [Unreleased]` to the given version (dated today unless a
date is passed), merges the pending fragments into it, opens a fresh empty
`## [Unreleased]`, and deletes the consumed fragment files.
