---
title: "Configuration Contract"
output: html_document
editor_options:
  markdown:
    wrap: 72
---

# Configuration Contract

## Purpose

This document defines the three configuration files that form the
**control plane** of the xpipe pipeline. Together they specify local
infrastructure, domain semantics, and ingestion mechanics.

Configuration is **contract-driven**: adding a new data stream or
ingestion method requires only a JSON update — no code change. This
document defines what each file must contain, what each field means,
and what constitutes a valid or breaking change.

## Overview of the Three Files

| File | Location | Role |
|---|---|---|
| `local.json` | `inst/_xne/local.json` | Local infrastructure (paths, logging) |
| `streams.json` | `data/shared/streams.json` | Domain semantics (what the data is) |
| `methods.json` | `data/shared/methods.json` | Ingestion mechanics (how to read it) |

`local.json` is **machine-specific** and is never shared. `streams.json`
and `methods.json` are the **shared brain** of the pipeline — they
travel with the data and define the domain contract for all operators.

All three files are validated against JSON schemas at load time using
the AJV engine via `jsonvalidate`. Schema validation is a hard abort.

---

## `local.json` — Local Infrastructure

### Purpose

Defines physical filesystem paths for each pipeline layer and optional
logging configuration. This file is local to the machine running the
pipeline and is not shared.

### Required Fields

```json
{
  "paths": {
    "shared": "data/shared",
    "batch":  "data/batch",
    "bronze": "data/bronze"
  }
}
```

| Field | Required | Meaning |
|---|---|---|
| `paths.shared` | Yes | Path to the shared brain directory (streams.json, methods.json) |
| `paths.batch` | Yes | Root of the Batch layer |
| `paths.bronze` | Yes | Root of the Bronze layer |
| `paths.inbox` | No | Inbox directory for raw source files |
| `paths.raw` | No | Optional raw archive path |
| `logging.level` | No | Log verbosity: `trace`, `debug`, `info`, `warn`, `error`, `fatal` |
| `logging.path` | No | Log file path |

### Change Policy

`local.json` changes are local and never affect pipeline semantics.
Paths may be updated freely without versioning or coordination.

---

## `streams.json` — Domain Semantics

### Purpose

Declares the semantic contract for each data stream: what the data
represents, how it should be partitioned in time, and what the temporal
anchor means. Streams define **what** the data is, not how to read it.

### Required Structure

```json
{
  "_meta": {
    "type": "streams_contract",
    "version": "1.0"
  },
  "sdo": {
    "label": "Scheda di Dimissione Ospedaliera",
    "schema_domain": "sdo",
    "partition_granularity": "year",
    "anchor": "start",
    "valid_from": "2020-01-01"
  }
}
```

### `_meta` Block

Every `streams.json` must include a `_meta` object with:

| Field | Required | Meaning |
|---|---|---|
| `type` | Yes | Must be the string `"streams_contract"` |
| `version` | Yes | Semantic version of the contract (e.g. `"1.0"`) |
| `created_at` | No | ISO date the file was first created |
| `last_updated` | No | ISO date of last change |
| `maintainer` | No | Name or role responsible for this contract |
| `change_policy` | No | Free-text description of the change governance |

### Stream Definition Fields

Each stream key (e.g. `"sdo"`) maps to an object with:

| Field | Required | Meaning |
|---|---|---|
| `label` | Yes | Human-readable stream name |
| `schema_domain` | Yes | Domain identifier; must match the `schema_domain` of all methods used with this stream |
| `partition_granularity` | Yes | `"year"` or `"month"` — controls Bronze partition layout |
| `anchor` | Yes | `"start"` or `"end"` — declares which event date is the temporal anchor |
| `valid_from` | Yes | ISO date from which this stream definition is valid |
| `valid_to` | No | ISO date after which this stream is deprecated (null if active) |
| `description` | No | Free-text description of the stream |

### Anchor Semantics

The `anchor` field declares the **temporal meaning** of the stream:

- `"start"` — the anchor date represents the beginning of the event
  (e.g. hospital admission date)
- `"end"` — the anchor date represents the end of the event
  (e.g. discharge date)

This is a semantic declaration. The pipeline records it in Batch
metadata and uses it for Bronze partitioning via the method's
`partition_column`. The anchor is **not computed** — it is declared by
governance.

### Change Policy

| Change type | Breaking? | Requires versioning? |
|---|---|---|
| Add a new stream | No | No |
| Change `label` or `description` | No | No |
| Change `partition_granularity` | **Yes** | Yes — changes Bronze layout |
| Change `anchor` | **Yes** | Yes — changes temporal meaning |
| Change `schema_domain` | **Yes** | Yes — breaks method compatibility |
| Deprecate a stream (`valid_to`) | No | Recommended |
| Remove a stream | **Yes** | Yes — breaks any active method referencing it |

---

## `methods.json` — Ingestion Mechanics

### Purpose

Declares how each data source is physically read, which tables it
contains, which columns are PHI, and how rows should be linked to the
anchor time for Bronze promotion. Methods define **how** to ingest —
not what the data means.

### Required Fields per Method

```json
{
  "sdo_campania_xml": {
    "schema_domain": "sdo",
    "type": "xml",
    "input_type": "directory",
    "anchor_table": "TblScheda",
    "identity_keys": ["id_nosologico"],
    "partition_column": "data_ricovero",
    "pseudonymize": ["cod_fiscale"],
    "skip": ["nome", "cognome"]
  }
}
```

| Field | Required | Meaning |
|---|---|---|
| `schema_domain` | Yes | Must match the `schema_domain` of the stream used with this method |
| `type` | Yes | Extraction instrument: `"access_mdb"`, `"xml"`, or `"csv"` |
| `input_type` | Yes | `"file"` or `"directory"` |
| `anchor_table` | Yes | Table whose `partition_column` drives Bronze time partitioning |
| `identity_keys` | Yes | Columns that uniquely identify a logical entity (used for Silver joining) |
| `partition_column` | Yes | Column in the anchor table used to derive the domain timestamp |
| `pseudonymize` | No | Column names to pseudonymize with HMAC-SHA256 before persistence |
| `skip` | No | Column names to drop entirely before persistence |
| `components` | No | Named glob patterns for multi-file directory inputs |
| `table` | No | Single table name override (for simple single-table methods) |
| `mapping` | No | Column rename map applied at extraction time |

### Schema Domain Compatibility

A method and the stream it is used with must declare the **same
`schema_domain`**. The pipeline enforces this at preparation time —
attempting to use a method with an incompatible stream is a hard abort
with class `xpipe_batch_schema_domain`.

### Anchor and Partition Column

The `anchor_table` and `partition_column` together determine how Bronze
partitions time:

- `anchor_table` — which extracted table is the "source of truth" for time
- `partition_column` — which column in that table contains the domain date

Secondary tables inherit `__anchor_time` by joining to the anchor table
on `identity_keys`. If secondary tables do not contain all `identity_keys`,
promotion aborts.

### Change Policy

| Change type | Breaking? | Notes |
|---|---|---|
| Add a new method | No | |
| Change `type` or `input_type` | **Yes** | Changes extraction behavior |
| Add a column to `pseudonymize` | **Yes** | Existing batches were not pseudonymized for that column |
| Remove a column from `pseudonymize` | **Yes** | New batches will differ from historical ones |
| Change `anchor_table` or `partition_column` | **Yes** | Changes Bronze partitioning — old shards may be mispartitioned |
| Change `identity_keys` | **Yes** | Breaks Silver joining |
| Add/change `skip` | **Yes** | Affects what data is persisted |
| Change `schema_domain` | **Yes** | Breaks stream compatibility |
| Change `components` patterns | Likely | May change what files are detected |

Any breaking change to a method effectively invalidates all existing
Batch artifacts produced with that method. Re-ingestion from source
is required for consistency.
