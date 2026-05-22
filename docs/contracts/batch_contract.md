---
date: 2026-05-22
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

The Batch layer does not determine temporal meaning, resolve identity,
deduplicate records, or apply domain business rules.

It is responsible for faithful extraction, contract-declared privacy
application, Batch-level type enforcement, artifact validation, and safe,
traceable persistence.

Batch is the last layer where declared semantic-preserving
transformations may occur. Bronze and Silver preserve what Batch
materializes.

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
3.  **Faithful extraction with declared Batch-time normalization**
    - Extractors return raw, syntactically valid data frames
    - Batch may apply only declared privacy rules and declared column type
      enforcement before persistence
    - No deduplication, aggregation, identity resolution, or business-rule
      filtering is performed
    - An empty extraction result is a hard abort
    - A table with zero columns is an invalid artifact and must not be
      written
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

#### Notes

- `<batch_id>` follows the format
  `<timestamp>_<stream_id>_<method_id>` when auto-generated, and is
  validated as a non-empty string when provided explicitly.
- All Parquet files in a batch directory represent tables materialized
  from a single ingestion event.
- `_batch_metadata.json` describes the batch event and its materialized
  tables.
- The physical presence of `<table_name>.parquet` files defines the
  authoritative set of materialized tables.
- Metadata must not be used to promote a table if the corresponding
  Parquet file is absent.

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
|---|---|---|
| `batch_id` | string | Unique batch identifier |
| `stream.id` | string | Target stream identifier |
| `stream.schema_domain` | string | Domain of the stream; must match the method |
| `stream.anchor` | enum | Temporal anchor declared by the stream (`start` / `end`) |
| `method.id` | string | Ingestion method used |
| `method.type` | string | Extraction instrument type |
| `input.path` | string | Full path of the original file or folder |
| `input.input_type` | enum | Whether input was a file or directory |
| `resolved_inputs` | object | Optional; physical input files resolved during preparation |
| `tables` | array | Tables actually materialized as Parquet files |
| `execution.created_at` | datetime | ISO-8601 timestamp of materialization |
| `execution.tool` | string | Tool/package name that produced the batch |
| `execution.tool_version` | string | Tool/package version that produced the batch |

### `_batch_metadata.json` — Semantics

- `stream.anchor` is declared by the stream configuration and recorded
  for traceability. It is not interpreted by Batch.
- `resolved_inputs`, when present, records the physical files resolved
  during Batch preparation.
- `tables` records the tables that were actually materialized as Parquet
  files.
- `_batch_metadata.json` is descriptive. Physical Parquet files remain
  authoritative for table materialization.
  
## Input Resolution Contract

Batch preparation resolves physical inputs before extraction.

Directory-based methods declare physical input patterns through
`input_files`.

Database-like methods declare logical source tables through
`source_tables`.

These concepts are separate:

- `input_files` describes physical files or file patterns in the inbox
- `source_tables` describes tables to extract from structured sources
  such as Access/MDB
- `output_tables` describes expected extractor outputs for validation
  and inspection

Extractors consume resolved inputs or declared source tables. They must
not infer behavior from legacy or overloaded fields.

## Privacy Rules

Privacy rules are optional and declared in the method configuration under
the `privacy` block.

If `privacy` is absent, Batch performs no privacy transformation for that
method. This is valid for streams that are already anonymized upstream or
do not require Batch-time privacy processing.

If `privacy` is present, rules are authoritative and must be applied
before any Parquet file is written.

Privacy rules are scoped by:

1. action: `hash` or `skip`
2. table name
3. column name
4. expected shape: `scalar` or `list`

Example:

```json
{
  "privacy": {
    "hash": {
      "ricovero": {
        "identificativoPaziente": "scalar",
        "codiceFiscale": "scalar"
      },
      "procedure": {
        "chirurgoIntervento": "list",
        "anestesistaIntervento": "list"
      }
    },
    "skip": {
      "ricovero": {
        "nome": "scalar",
        "cognome": "scalar"
      }
    }
  }
}
```

`privacy.skip` removes declared columns entirely.

`privacy.hash` pseudonymizes declared scalar values or list-column
elements using HMAC-SHA256 and the runtime pepper key.

List-column hashing preserves list structure and cardinality.

If the declared shape does not match the extracted column shape, Batch
materialization must abort.

The pepper key is a runtime secret (XNE_PEPPER_KEY) that is never
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

For XML methods, `extract_xml()` is a dispatcher.

The concrete XML parser is selected through the method-level
`xml_profile` field.

Each XML profile is implemented in code and registered in the XML profile
registry. XML parsing logic is not described declaratively in
`methods.json`.

## Ingestion Phases

Batch materialization proceeds in four sequential phases:

| Phase | Name                           | Side effects      | Aborts on failure |
|----------------|-----------------------|----------------|----------------|
| A     | Pre-materialization guardrails | None              | Yes               |
| B     | Instrument resolution          | None              | Yes               |
| C     | Data extraction                | In-memory only    | Yes               |
| D     | Batch persistence              | Filesystem writes | Yes               |

Phases A and B are fully non-destructive.

During Phase C, extraction produces raw in-memory data frames.

Before Phase D writes any files, Batch applies:

1. `privacy.skip`
2. `privacy.hash`
3. `column_types` enforcement
4. artifact validation

A batch directory is created only during persistence. Metadata is written
after Parquet files have been successfully materialized.


## Guardrails (Phase A)

Before any extraction begins, the pipeline enforces:

-   **Collision guard**: aborts if the target batch directory already
    exists
-   **Input existence**: aborts if the input path no longer exists at
    materialization time (it may have been moved after preparation)
-   **Input non-empty**: aborts if the input file is 0 bytes
- **Input contract guard**: directory methods must define `input_files`
- **Source table guard**: database-like methods must define
  `source_tables`
  
## Dry Run and Confirmation

`ingest_batch()` supports:

-   `dry_run = TRUE`: performs preparation and prints the recap, but
    never materializes. No filesystem side effects.
-   `confirm = TRUE` (default in interactive sessions): shows a recap
    and requests explicit confirmation before materialization begins.

## What the Batch Layer Explicitly Does NOT Do

- Assign temporal meaning to records
- Resolve entity identity or duplicates
- Determine current state
- Apply domain business rules
- Harmonize schemas across methods
- Interpret clinical or administrative semantics beyond declared Batch
  contracts
- Repair privacy or type errors downstream

These responsibilities are delegated to Bronze (temporal partitioning)
and Silver (identity resolution and current state).

## Guarantees for Downstream Layers

A complete batch guarantees:

- The anchor table was materialized as a valid Parquet file.
- No zero-column Parquet files were written.
- Materialized Parquet files define the authoritative table set.
- Declared privacy rules were applied before Parquet writing.
- Declared column type rules were enforced before Parquet writing.
- Full provenance is recorded: source path, resolved inputs, method,
  stream, timestamp, tool, and tool version.
- The batch directory will never be modified after creation.

Bronze promotion may safely assume these guarantees only for complete
batches with `_batch_metadata.json` and physically present Parquet files.
