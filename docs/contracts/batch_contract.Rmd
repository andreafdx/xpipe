---
title: "Batch Layer Contract"
output: html_document
editor_options:
  markdown:
    wrap: 72
---

# Batch Layer Contract

## Purpose

The Batch layer is the **first and only entry point** for raw data into
the pipeline. It converts a source artifact — a file or directory in the
inbox — into a canonical, immutable representation ready for downstream
promotion.

Each batch is a **self-contained, atomic event**: it captures what was
extracted, from where, when, and by which method, and packages it as a
set of typed Parquet files accompanied by a structured metadata
document.

The Batch layer does not interpret data. It does not determine temporal
meaning, resolve identity, or perform deduplication. Its only
responsibility is faithful, lossless extraction and safe, traceable
persistence.

## Core Invariants (Non‑Negotiable)

1.  **Immutable once materialized**
    -   A batch directory is written once and never modified
    -   Re‑ingesting the same source produces a new batch with a new
        identifier, not an overwrite
    -   Collision with an existing batch directory is a hard abort
2.  **Atomic materialization**
    -   Privacy rules are applied in-memory before any file is written
    -   Metadata is written last, after all Parquet files succeed
    -   A batch without `_batch_metadata.json` is considered incomplete
        and is excluded from downstream promotion
3.  **Faithful extraction**
    -   Domain columns are written as-is, without semantic
        transformation
    -   No deduplication, filtering, or aggregation is performed
    -   An empty extraction result is a hard abort
4.  **Schema‑domain isolation**
    -   Method and stream must declare the same `schema_domain`
    -   Cross-domain ingestion is rejected at preparation time, before
        any I/O occurs

## Physical Layout

```         
batch/
  <batch_id>/
    <table_name>.parquet   (one per extracted table)
    _batch_metadata.json
```

### Notes

-   `<batch_id>` follows the format
    `<timestamp>_<stream_id>_<method_id>` when auto-generated, and is
    validated as a non-empty string when provided explicitly
-   All Parquet files in a batch directory represent tables extracted
    from a single ingestion event
-   `_batch_metadata.json` is the authoritative record of that event;
    its presence signals that the batch is complete and promotable

## Batch Identifier

The batch identifier is the stable, unique key for a batch event across
the entire pipeline.

-   Auto-generated format: `YYYYMMDDTHHMMSSsss_<stream_id>_<method_id>`
-   Explicitly provided identifiers are accepted but must be non-empty
-   The identifier is scoped to the Batch layer root; uniqueness is
    enforced by filesystem collision detection

## Metadata Model

### `_batch_metadata.json` — Required Fields

Each batch directory **must** contain a `_batch_metadata.json` file
conforming to `batch_metadata.schema.json`. The schema enforces:

| Field | Type | Meaning |
|-----------------|-----------------|--------------------------------------|
| `batch_id` | string | Unique batch identifier |
| `stream.id` | string | Target stream identifier |
| `stream.schema_domain` | string | Domain of the stream (must match method) |
| `stream.anchor` | enum | Temporal anchor declared by stream (`start`/`end`) |
| `method.id` | string | Ingestion method used |
| `method.type` | string | Extraction instrument type |
| `input.path` | string | Full path of the original file or folder |
| `input.input_type` | enum | Whether input was a `file` or `directory` |
| `execution.created_at` | datetime | ISO‑8601 timestamp of materialization |
| `execution.tool` | string | Package name that produced the batch |
| `components` | object | Optional; logical named components (directory inputs only) |

### `_batch_metadata.json` — Semantics

-   `stream.anchor` is **declared by the stream configuration** and
    recorded for traceability. It is not interpreted at this layer.
-   `components` is present only for directory-based ingestion methods
    and maps logical component names to glob patterns.

## Privacy Rules

Privacy rules are applied **before any data touches disk**.

The method configuration may declare:

-   `pseudonymize`: a list of column names to be hashed via HMAC‑SHA256
    using the runtime pepper key
-   `skip`: a list of table names to drop entirely from the batch

Rules are applied in-memory during Phase C (extraction), before Phase D
(persistence). No raw PHI is ever written to the Batch layer.

The pepper key is a runtime secret (`XNE_PEPPER_KEY`) that is never
persisted and never embedded in configuration files.

## Extraction Instruments

An extraction instrument is a function that converts a source file or
directory into a named list of data frames. The instrument is selected
by matching `method.type` against an internal registry:

| Method type  | Instrument function |
|--------------|---------------------|
| `access_mdb` | `extract_access_db` |
| `xml`        | `extract_xml`       |

An unregistered or unloaded instrument is a hard abort before extraction
begins.

## Ingestion Phases

Batch materialization proceeds in four sequential phases:

| Phase | Name                           | Side effects      | Aborts on failure |
|----------------|-----------------------|----------------|----------------|
| A     | Pre-materialization guardrails | None              | Yes               |
| B     | Instrument resolution          | None              | Yes               |
| C     | Data extraction                | In-memory only    | Yes               |
| D     | Batch persistence              | Filesystem writes | Yes               |

Phases A and B are fully non-destructive. A batch directory is only
created in Phase D, after all in-memory operations have succeeded.

## Guardrails (Phase A)

Before any extraction begins, the pipeline enforces:

-   **Collision guard**: aborts if the target batch directory already
    exists
-   **Input existence**: aborts if the input path no longer exists at
    materialization time (it may have been moved after preparation)
-   **Input non-empty**: aborts if the input file is 0 bytes

## Dry Run and Confirmation

`ingest_batch()` supports:

-   `dry_run = TRUE`: performs preparation and prints the recap, but
    never materializes. No filesystem side effects.
-   `confirm = TRUE` (default in interactive sessions): shows a recap
    and requests explicit confirmation before materialization begins.

## What the Batch Layer Explicitly Does NOT Do

-   Assign temporal meaning to records
-   Resolve entity identity or duplicates
-   Determine partition keys for downstream layers
-   Apply domain business rules
-   Modify any data after extraction

These responsibilities are delegated to Bronze (temporal partitioning)
and Silver (identity resolution and current state).

## Guarantees for Downstream Layers

A complete batch (with `_batch_metadata.json`) guarantees:

-   All extracted tables are present as typed Parquet files
-   Privacy rules have been applied to all declared PHI columns
-   Full provenance is recorded (source, method, stream, timestamp,
    tool)
-   The batch directory will never be modified after creation

Bronze promotion may safely assume these guarantees hold for any batch
it encounters.
