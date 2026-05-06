# ADR-005: Separate streams.json and methods.json Configuration Files

**Date**: 2026-04-07 (approx.)
**Status**: Accepted
**Decider**: Andrea Fidecicchi

## Context

The pipeline needs to configure both domain semantics (what the data
means — temporal anchor, partition granularity, identity) and extraction
mechanics (how to read it — file type, table names, column mappings,
privacy rules). These two concerns evolve at different rates and are
owned by different conceptual roles (domain governance vs. technical
extraction).

## Decision

Split configuration into two files:

- `streams.json` — **what** the data is (domain semantics, stable)
- `methods.json` — **how** to read it (extraction mechanics, changes
  with each new source or format)

A method declares `schema_domain` and a stream declares `schema_domain`;
the pipeline enforces that they match before ingestion begins.

## Alternatives Considered

- **Single unified config file**: simpler to manage, but conflates
  governance-level decisions (anchor semantics, partitioning) with
  technical details (table names, ODBC queries). A DPO reviewing
  privacy rules should not need to understand MDB extraction mechanics.
  Not chosen.
- **Per-stream method embedding** (methods nested inside streams):
  would prevent reusing a method across streams and would force
  temporal semantics and extraction details to change together. Not
  chosen.

## Consequences

- Domain governance and technical extraction can evolve independently.
- A new file format for an existing stream (e.g. switching from MDB to
  XML for the same SDO stream) requires adding a new method only, with
  no change to the stream definition.
- The `schema_domain` coupling between stream and method is a minimal
  contract that prevents silently ingesting incompatible data.
- Two files must be kept in sync in terms of `schema_domain` values;
  a mismatch is caught at runtime, not at authoring time.
