# ADR-010: Batch Retraction Policy

**Date**: 2026-05-06
**Status**: Open — no mechanism defined yet

## Context

The pipeline is designed to be append-only and immutable at every layer.
This is the correct default for an audit ledger. However, real-world
healthcare data operations produce situations where a batch should
arguably be "undone":

- The source file was corrupted or contained wrong data
- The wrong file was ingested (wrong year, wrong hospital)
- A privacy rule was misconfigured and the batch was ingested with
  unintentional column exposure
- A method configuration bug produced incorrect pseudonymization

Currently, there is no defined mechanism for handling any of these cases.
A batch, once promoted to Bronze, is permanent.

## Open Questions

1. **Should retraction be a supported operation?** The append-only
   invariant exists for a reason. Any retraction mechanism must be
   explicitly authorised and logged, or it undermines the audit guarantee.

2. **If yes, at which layer?**
   - Batch only: remove the batch directory; the promotion log still
     references a now-missing batch
   - Bronze only: delete specific shards; Silver re-derives from
     remaining Bronze
   - Both: complex, requires coordination

3. **What is the retraction record?** If a shard is removed, how is
   the absence of a previously-present shard documented? An "anti-event"
   in the promotion log?

4. **Is re-ingestion the correct solution?** Rather than retracting,
   the standard medallion approach is: ingest a corrected version,
   promote it to Bronze, and rebuild Silver from the corrected Bronze.
   This leaves the incorrect batch in Bronze as a historical record with
   a note. Silver always reflects the latest version.

## Recommendation (tentative)

Do not implement retraction. Instead:

- Document that Bronze is a historical ledger that intentionally preserves
  incorrect data as a fact of what was delivered at that time
- Silver's "latest wins" model naturally overrides incorrect older batches
  once a corrected version is ingested
- For cases of incorrect PHI handling (missing pseudonymization), treat
  the incident as a data breach event and escalate to the DPO rather
  than silently patching the pipeline output
