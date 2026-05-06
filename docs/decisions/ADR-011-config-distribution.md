# ADR-011: Configuration Distribution and Version Control

**Date**: 2026-05-06
**Status**: Open — operational policy not yet defined

## Context

`streams.json` and `methods.json` are the shared brain of the pipeline.
They define the domain contract for all operators. The pipeline reads
them from the path declared in `local.json` (`paths.shared`), which
on any given machine points to a local directory.

The question is how these files are version-controlled, distributed
to multiple operators, and kept in sync as the domain contract evolves.

The original pipeline documentation mentions "distributed SharePoint
libraries" as the deployment context.

## Open Questions

1. **Source of truth**: is `streams.json`/`methods.json` version-
   controlled in a Git repository? On SharePoint? On a network drive?
   There is currently no canonical answer.

2. **Distribution**: when `streams.json` is updated (new stream added,
   anchor semantics changed), how do all operators get the update?
   Manually copying files is error-prone. SharePoint sync may work but
   introduces latency and conflicts.

3. **Version management**: the `_meta` block in `streams.json` includes
   a `version` field, but the pipeline does not enforce a minimum
   version. A machine running an old copy of `streams.json` will not
   be warned. Should `load_xpipe_config()` validate the version against
   a minimum declared in the package?

4. **Breaking change propagation**: if `streams.json` introduces a
   breaking change (e.g. `schema_domain` rename), operators running
   an old config will produce incompatible batches silently. Is there
   a mechanism to detect this?

5. **Access control**: can any operator modify `methods.json`? Should
   the `pseudonymize` field require review before changes are deployed?

## Dependency

This decision affects how reliably the pipeline contract is maintained
across all installations. An inconsistency in `methods.json` between
two operators could lead to some batches being pseudonymized differently
from others — a silent data integrity failure.

## Recommendation (tentative)

- Store `streams.json` and `methods.json` in a Git repository (or a
  SharePoint folder with version history enabled)
- Treat any change to `pseudonymize`, `identity_keys`, `anchor_table`,
  or `partition_column` as a breaking change requiring review
- Consider adding a minimum `_meta.version` check in `load_xpipe_config()`
  so that operators with outdated configs receive an explicit warning
  rather than running silently with stale definitions
