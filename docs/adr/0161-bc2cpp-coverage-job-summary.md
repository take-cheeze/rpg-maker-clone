# 0161: Publish the bc2cpp coverage report in CI summaries

Date: 2026-09-20

## Status

Accepted

## Context

The whole-program bc2cpp coverage report was committed as
`docs/bc2cpp_coverage.txt`. Its aggregate dispatch counts change whenever
bc2cpp or the compiled Ruby sources change. That made unrelated bc2cpp pull
requests collide on a generated file and caused CI to fail whenever the
snapshot was stale.

## Decision

Keep the report generator, but have it print the stats report to stdout by
default. The build workflow runs it against the host `mrbc` built by that job
and publishes the report in the GitHub Actions job summary. Delete the tracked
`docs/bc2cpp_coverage.txt` snapshot. The standalone optcarrot probe report
remains tracked because it is a separate, stable measurement of that probe's
closed world.

## Consequences

- Every build report is visible with the CI run that generated it, without
  requiring a generated-file update in each bc2cpp pull request.
- PR descriptions can include the relevant report for review; aggregate counts
  no longer create repository merge conflicts.
- The workflow reports measurements but no longer fails solely because
  aggregate counts differ from an older committed snapshot.
