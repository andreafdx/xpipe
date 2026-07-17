---
date: 2026-05-22
---

# Configuration Contract

## Purpose

This document defines the three configuration files that form the
**control plane** of the xpipe pipeline. Together they specify local
infrastructure, domain semantics, and ingestion mechanics.

Configuration is **contract-driven**, but not all extensions are purely
declarative.

Adding a new stream or a new method using an existing extractor/profile
is a JSON-only change.

Adding a new extractor type or a new XML profile requires code: the
parser or extractor must be implemented and registered, then selected
from `methods.json`.

## Overview of the Configuration Files

The control plane is defined by shared and local JSON contracts.

| File | Location | Role |
|---|---|---|
| `xne.json` | `xne.json` (fallback `inst/xne.local.json`) | Local infrastructure: paths, meta, and logging |
| `streams.json` | `data/shared/streams.json` | Domain semantics: what the data represents |
| `methods.json` | `data/shared/methods.json` | Ingestion mechanics: how source data is read and normalized into Batch |
| `silver.json` | `data/shared/silver.json` | Silver layer configuration: canonical method selection and harmonization profiles per stream |

`xne.json` is machine-specific and is not shared across repositories.

`streams.json`, `methods.json`, and `silver.json` are shared control-plane
contracts. They travel with the data and define the operational behavior
of the pipeline.

---

## `xne.json` — Local Infrastructure

### Purpose

Defines physical filesystem paths for each pipeline layer, configuration metadata,
and optional logging configuration. This file is local to the machine running the
pipeline and is not shared.

### Required Fields

```json
{
  "meta": {
    "config_version": "1.0",
    "project": "xne",
    "description": "Path configuration for xne medallion analytic framework",
    "created_at": "2026-07-17",
    "last_updated_at": "2026-07-17"
  },
  "paths": {
    "shared": "data/shared",
    "inbox": "inbox",
    "batch": "data/batch",
    "bronze": "data/bronze",
    "silver": "data/silver"
  }
}
```

| Field | Required | Meaning |
|---|---|---|
| `meta.config_version` | Yes | Semantic version of the configuration structure (e.g. `"1.0"`) |
| `meta.project` | Yes | Project identifier (e.g. `"xne"`) |
| `meta.description` | Yes | Description of the configuration purpose |
| `meta.created_at` | Yes | ISO date of creation |
| `meta.last_updated_at` | Yes | ISO date of last update |
| `paths.shared` | Yes | Path to the shared contract directory (streams.json, methods.json, silver.json) |
| `paths.inbox` | Yes | Inbox directory for raw input source files |
| `paths.batch` | Yes | Root directory of the Batch layer |
| `paths.bronze` | Yes | Root directory of the Bronze layer |
| `paths.silver` | Yes | Root directory of the Silver layer |
| `logging.level` | No | Log verbosity: `trace`, `debug`, `info`, `warn`, `error`, `fatal` |
| `logging.path` | No | Log file path |

### Change Policy

`xne.json` changes are local to the deployment environment and never affect shared pipeline semantics.
Paths and metadata dates may be updated freely without versioning or external coordination.

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

### Required Structure

Example for XML method: 

```json
{
  "xml_campania_2026": {
    "schema_domain": "sdo",
    "type": "xml",
    "input_type": "directory",
    "xml_profile": "sdo_tracciato_abcd",
    "input_files": {
      "file_a": "*_A.xml",
      "file_b": "*_B.xml"
    },
    "output_tables": {
      "required": ["ricovero"],
      "optional": ["diagnosi", "procedure", "trasferimenti", "accessi_dh"]
    },
    "anchor_table": "ricovero",
    "identity_keys": ["codiceIstitutoDiCura", "progressivoSDO"],
    "partition_column": "dim_dataDimissioneMorte",
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
    },
    "column_types": {
      "ricovero": {
        "codiceIstitutoDiCura": "character",
        "progressivoSDO": "character"
      }
    }
  }
}
```

Example Access/MDB method:

```json
{
  "quani_mdb": {
    "schema_domain": "sdo",
    "type": "access_mdb",
    "input_type": "file",
    "source_tables": [
      "TblScheda",
      "TblSchedaDiagnosi",
      "TblSchedaProcedure"
    ],
    "anchor_table": "TblScheda",
    "identity_keys": ["i_IDScheda"],
    "partition_column": "d_DataDimissione",
    "privacy": {
      "hash": {
        "TblScheda": {
          "c_CodicePaziente": "scalar"
        }
      },
      "skip": {
        "TblScheda": {
          "v_Nome": "scalar",
          "v_Cognome": "scalar"
        }
      }
    }
  }
}
```

### Input and Source Semantics


| Field | Required | Meaning |
|---|---:|---|
| `schema_domain` | Yes | Semantic domain of the method. Must match the stream `schema_domain`. |
| `type` | Yes | Extraction instrument: `access_mdb`, `xml`, or `csv`. |
| `input_type` | Yes | Expected inbox input shape: `file` or `directory`. |
| `xml_profile` | Required for `type = "xml"` | Code-driven XML parser profile registered in the XML profile registry. |
| `input_files` | Required for directory methods | Named physical file patterns resolved during Batch preparation. |
| `source_tables` | Required for `access_mdb` | Logical source tables to extract from database-like inputs. |
| `output_tables` | No | Expected output tables, split into `required` and `optional`. Informational in this branch. |
| `anchor_table` | Yes | Required anchor table produced by the method. |
| `identity_keys` | Yes | Columns identifying a logical entity; used by Silver-current joins. |
| `partition_column` | Yes | Domain-time column retained as method metadata and future semantic input. It is not used to determine Silver-current. |
| `privacy` | No | Optional table/column/shape-aware privacy rules. If absent, no Batch-time privacy transformation is applied. |
| `column_types` | No | Per-table type enforcement rules applied in Batch after privacy and before Parquet writing. |


`input_files` and `source_tables` are intentionally separate.

`input_files` describes physical input files or file patterns resolved
during Batch preparation. It is used for directory-style inputs such as
XML batches.

`source_tables` describes logical tables to extract from a structured
source such as Access/MDB.

These concepts must not be collapsed into a single field.

Extractors consume resolved inputs or declared source tables. They must
not infer behavior from legacy or overloaded fields.

### Privacy Semantics

Privacy rules are declared under the optional `privacy` block.

Rules are scoped by:

1. action: `hash` or `skip`
2. table name
3. column name
4. expected shape: `scalar` or `list`

If `privacy` is absent, the pipeline performs no Batch-time privacy
transformation for that method.

If `privacy` is present, declared rules are authoritative. Shape
mismatches between the contract and extracted data cause Batch
materialization to abort.

`privacy.skip` removes declared columns.

`privacy.hash` pseudonymizes declared scalar values or list-column
elements while preserving list structure.

### Schema Domain Compatibility

A method and the stream it is used with must declare the **same
`schema_domain`**. The pipeline enforces this at preparation time —
attempting to use a method with an incompatible stream is a hard abort
with class `xpipe_batch_schema_domain`.

### Anchor Table, Identity Keys, and Partition Column

`anchor_table` declares the required core table for the method.

`identity_keys` declare the columns that identify a logical entity within
the stream. Silver-current uses these keys, together with `__batch_id`,
to join secondary tables back to the selected current anchor version.

`partition_column` records the domain-time column associated with the
method. It remains method metadata and may be used by future semantic or
harmonized layers.

Silver-current does not use `partition_column` or domain anchor time to
determine currentness. Currentness is defined only by ingestion order:

```sql
ORDER BY __batch_created_at DESC, __batch_id DESC
```

### Change Policy

| Change type | Breaking? | Notes |
|---|---:|---|
| Add a new method using an existing extractor/profile | No | JSON-only change if schema-compatible. |
| Add a new XML profile | Yes | Requires parser implementation and registry update. |
| Change `type` or `input_type` | Yes | Changes extraction behavior. |
| Change `input_files` | Likely | May change which physical files are read. |
| Change `source_tables` | Likely | May change which source tables are extracted. |
| Change `output_tables` | No/Maybe | Informational in this branch; may affect inspection/validation later. |
| Add or change `privacy.hash` | Yes | Existing batches were not hashed with the new rule. Re-ingestion required for consistency. |
| Add or change `privacy.skip` | Yes | Changes persisted schema. Re-ingestion required for consistency. |
| Remove a privacy rule | Yes | New batches will contain different privacy treatment from historical batches. |
| Change privacy shape (`scalar`/`list`) | Yes | Changes expected data structure and validation behavior. |
| Change `anchor_table` | Yes | Changes required anchor table and Silver-current base. |
| Change `identity_keys` | Yes | Breaks Silver-current entity selection and secondary joins. |
| Change `partition_column` | Yes/Maybe | Does not affect Silver-current, but changes domain-time metadata and future semantic processing. |
| Change `schema_domain` | Yes | Breaks stream compatibility. |

Any breaking change to a method may invalidate existing Batch artifacts
produced with that method.

Changes to privacy rules, identity keys, anchor tables, source selection,
or input resolution require explicit governance review.

When a change alters persisted data semantics or privacy treatment,
re-ingestion from source is required for consistency.

## `silver.json` — Silver Layer Configuration

### Purpose

Declares which method is canonical for Silver-current for each stream,
enables Silver-harmonized, and maps table/column-renaming normalizations.

### Required Structure

```json
{
  "_meta": {
    "type": "silver_contract",
    "version": "0.2.0"
  },
  "streams": {
    "sdo": {
      "canonical_method": "xml_campania_2026",
      "current": {
        "enabled": true
      },
      "harmonized": {
        "enabled": true,
        "profile": "sdo_harmonized_v1",
        "tables": {
          "ricovero": {
            "source": "ricovero",
            "columns": {
              "codice_istituto_di_cura": "codiceIstitutoDiCura",
              "progressivo_sdo": "progressivoSDO",
              "drg": "DRG"
            }
          }
        }
      }
    }
  }
}
```

### Fields

| Field | Required | Meaning |
| :--- | :---: | :--- |
| `_meta.type` | **Yes** | Must be `silver_contract`. |
| `_meta.version` | **Yes** | Contract version. |
| `streams.<stream_id>.canonical_method` | **Yes** | Method used to build Silver-current for that stream. |
| `streams.<stream_id>.current.enabled` | **Yes** | Whether Silver-current is enabled for the stream. |
| `streams.<stream_id>.harmonized.enabled` | **Yes** | Whether Silver-harmonized is enabled for the stream. |
| `streams.<stream_id>.harmonized.profile` | Yes if harmonized | Registered harmonization profile function to apply (e.g., `sdo_harmonized_v1`). |
| `streams.<stream_id>.harmonized.tables` | Yes if harmonized | Map of harmonized output tables, their sources, and column mappings. |

### Rules

* The canonical method must exist in `methods.json`.
* The canonical method `schema_domain` must match the stream `schema_domain`.
* Both `phase = "current"` and `phase = "harmonized"` (or `phase = "all"`) are fully supported.
