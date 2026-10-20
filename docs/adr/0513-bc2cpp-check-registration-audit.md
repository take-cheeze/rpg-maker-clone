# 0513. Audit bc2cpp check registrations and compiler capabilities

Date: 2026-10-20

## Status

Accepted

## Context

Check consolidation changes both entrypoints and scheduling. A check listed
only in the host coverage runner may skip its MRBC section, while a deleted
or duplicated entry can silently undermine a reorganization. The inventory
also contains older checks never scheduled by ordinary CI and argument-driven
review utilities whose names end in `_check.rb`.

## Decision

Read the existing coverage `--list` output and workflow shell commands as the
execution sources of truth. Compare them with the discovered bc2cpp check
files. Require a registration or an explained deferral for every new check;
reject missing paths and duplicate registrations within one execution site.
Permit separate host and compiler runs of the same check.

Make the newly enabled MRBC fixtures an explicit required set in the registry
validator. Register eight fast host checks through coverage and seven compiler
checks in the existing bounded pool. Fix the standalone argument-type suite's
missing numeric IR dependency rather than accepting its errors.

Keep existing heavier runtime/mutation/generation audits in an explained
deferral inventory. Allow obsolete deferral entries temporarily so independent
consolidation branches can merge in either order; they do not satisfy a new
check at another path and cannot hide stale execution references.

## Consequences

Future checks cannot silently acquire no execution site, and compiler fixture
registration is tested independently of a host-only pass. The newly exercised
fixtures add useful work to CI, so this audit is a coverage improvement rather
than a job-time optimization. The deferred inventory makes remaining gaps
visible without adding every expensive historical audit to every pull request.

[ADR 0515](0515-bc2cpp-check-tier-policy.md) replaces the temporary string-only
deferral inventory with complete active/deferred prerequisite metadata and
rejects obsolete inventory paths. Execution lists remain authoritative.
