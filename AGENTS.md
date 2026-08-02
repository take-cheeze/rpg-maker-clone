# Project Guidelines

## Documentation Requirements

-   Update relevant documentation in /docs when modifying features
-   Keep README.md in sync with new capabilities
-   Maintain changelog entries in CHANGELOG.md

## Architecture Decision Records

Create ADRs in /docs/adr for:

-   Major dependency changes
-   Architectural pattern changes
-   New integration patterns
-   Database schema changes
    Follow template in /docs/adr/template.md

## Code Style & Patterns

- Codes are formatted by precommit. Please run it after code edit finishes
- Most dependencies are managed by nix flake. See flake.nix for detail

## Error Handling

- Do not silence errors. Never swallow an exception (or ignore a failing
  return value) so that a failure disappears without a trace.
- When you catch an error to keep the game running (e.g. a missing asset or
  optional data field falling back to a default), still surface it — log it to
  `$stderr` with a `[RPG2k]`/`[RGSS]` tag and the underlying `e.message`, the
  way the rest of the runtime code already does. A recovered error should be
  visible in the log, not invisible.
- Prefer catching the narrowest exception you can. Avoid bare `rescue` /
  broad `rescue StandardError` when a specific class expresses the real
  failure you are recovering from.

## Testing Standards

- Unit tests are written using Google Test and executed by CTest. Use `cmake --build build -t test` to run it
