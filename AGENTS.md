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

## Testing Standards

- Unit tests are written using Google Test and executed by CTest. Use `cmake --build build -t test` to run it
