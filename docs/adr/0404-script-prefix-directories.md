# 0404. Group scripts by their filename prefixes

Date: 2026-10-12

## Status

Accepted

## Context

The flat scripts directory contains hundreds of checks and utilities. Repeated
engine, target and compiler prefixes make browsing difficult, and obscure the
small collection of standalone utilities.

## Decision

Move recurring prefix families into matching directories and remove the prefix
from each basename. Keep standalone scripts and existing fixtures at the top
level. Update callers, relative imports, repository-root resolution, CI cache
patterns and label rules together. Document the layout in `docs/scripts.md`.

## Consequences

Related checks and helpers are adjacent and have shorter names. Existing flat
command paths must be updated; no forwarding wrappers are retained. Grouped
scripts resolve the repository root two levels above their own directory, and
check discovery must recurse. Historical changelog entries keep their original
paths.
