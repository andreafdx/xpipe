---
date: 2026-05-22
---

# Silver — Contract Specification

This document defines the semantic contract of the Silver layer. Silver
is the layer where raw ingested data is stabilized, versioned, and made
usable for downstream interpretation and analysis.

Silver is composed of two sequential phases:

-   Silver‑current: version stabilization
-   Silver‑harmonized: analytical normalization

Each phase has distinct responsibilities and guarantees.

## Silver‑current

### Purpose and scope

Silver‑current represents the authoritative **current state** of a data
stream, derived from the Bronze layer by applying an explicit,
reproducible version‑selection rule.

It is the first layer in the pipeline that makes a **semantic claim**
about the data:

> for each logical entity in the stream, this is the version selected as
> current according to ingestion order, optionally limited by an ingestion
> snapshot (`as_of`).

Silver‑current does not perform analytical harmonization, cross‑stream
integration, or domain interpretation beyond version validity.

### Canonical method selection

For each stream, Silver-current is built from exactly one canonical
ingestion method.

The canonical method is declared in `data/shared/silver.json` under:

```json
{
  "streams": {
    "<stream_id>": {
      "canonical_method": "<method_id>",
      "current": {
        "enabled": true
      }
    }
  }
}
```

If multiple Bronze methods exist for the same stream, only the canonical
method contributes to Silver-current.

Silver-current must never infer, rank, or guess the canonical method.

Canonicality is a governance decision recorded in configuration, not a
computed outcome.

The canonical method must exist in `methods.json`, and its
`schema_domain` must match the stream `schema_domain`.

### Entity identity

Each logical entity in the stream is uniquely identified by the set of
`identity_keys` defined by the canonical method.

All rows sharing the same identity keys represent **different versions
of the same entity**, never distinct entities.

This assumption is mandatory. If violated, Silver‑current is invalid.

### Versioning model

Data is versioned by Batch ingestion.

The technical version markers used by Silver-current are:

```text
__batch_created_at
__batch_id
```

Each promoted Bronze row carries these lineage fields.

For a given logical entity, different batches may contain different
versions of the same entity.

A version consists of:

- one selected row in the anchor table
- zero or more rows in each secondary table sharing the same
`identity_keys` and `__batch_id`

Version consistency across the Silver-current table family is enforced
by filtering secondary tables through the selected current anchor rows.

### Definition of “current”

For each entity (`identity_keys`), Silver-current selects the row from
the latest eligible imported batch containing that entity.

Eligibility is determined by the optional ingestion snapshot `as_of`.

If `as_of` is provided, only Bronze rows satisfying the following
condition are eligible:


```sql
__batch_created_at <= as_of
```

If `as_of` is absent, all Bronze rows for the canonical method are
eligible.

Currentness is determined among eligible rows only by ingestion lineage:

```sql
ROW_NUMBER() OVER (
  PARTITION BY identity_keys
  ORDER BY __batch_created_at DESC, __batch_id DESC
)
```

The current anchor row is the row with `rn = 1`.

`as_of` is an ingestion timestamp. It does not refer to clinical dates,
event dates, discharge dates, admission dates, or stream anchor semantics.

The concept of “current” depends **only on ingestion order**, not domain time.

### Anchor table behavior

Version selection is applied **exclusively to the anchor table**.

For each identity key: 

- exactly one anchor row is selected as current 
- that row determines the current version of the entity

The anchor table is the sole table that participates in version
selection.

### Secondary table behavior

Secondary tables do not participate in version selection.

Version selection is performed on the anchor table only.

After the current anchor row has been selected for each entity,
secondary tables are filtered by joining to the current anchor table
using:

```text
identity_keys + __batch_id
```

Only secondary rows belonging to the same selected batch version as the
current anchor row are retained.

Secondary tables have no independent notion of currentness.

### Relationship to stream temporal semantics

Silver‑current does **not** interpret the temporal meaning of the
stream.

The stream‑level `anchor` property (e.g. start vs end) defines how
events are assigned to institutional periods and is part of stream
semantics, not versioning logic.

Silver‑current produces a dataset that is “current”, not “of a given
period”.

### Relationship to Bronze

Silver-current is built from Bronze DuckDB tables.

For a given stream, Silver-current reads only Bronze tables belonging to
the canonical method declared in `silver.json`.

Bronze table names follow the pattern:

```text
<stream_id>__<method_id>__<source_table_name>
```

Silver-current does not inspect filesystem partitioning to determine
lineage or currentness.

Lineage is derived from Bronze metadata columns (`__batch_id`,
`__batch_created_at`, `__stream_id`, `__method_id`) and from the Bronze
promotion log.



### Persistence and physical layout

Silver-current is persisted as DuckDB tables.

The physical layout is one DuckDB database per stream:

```text
data/silver/<stream_id>.duckdb
```

Inside the stream database, Silver-current tables use the naming pattern:
```text
current__<source_table_name>
```
Example:

```text
data/silver/sdo.duckdb
  current__ricovero
  current__diagnosi
  current__procedure
```

Silver-current is rebuilt as a table family using `CREATE OR REPLACE TABLE`.

It must not append across runs, mix methods, or retain partial table
state from previous builds.

Physical partitioning is not part of the current Silver-current
contract. If introduced later, it must not alter the definition of
currentness.

## Silver‑harmonized

Silver-harmonized is part of the long-term Silver contract, but it is not
implemented in the current branch.

The implemented Silver behavior currently covers Silver-current only.

### Purpose and scope

Silver‑harmonized represents the **analytical form** of a stream,
derived from Silver‑current by applying explicit normalization and
enrichment rules.

Its purpose is to provide a **stable, method‑agnostic interface** for
analysis, indicators, and downstream pipelines.

Silver‑harmonized does not redefine versioning logic and does not
re‑evaluate “currentness”.

### Input and dependency

Silver‑harmonized is built **exclusively from Silver‑current**.

All versioning, deduplication, and entity selection decisions are
inherited unchanged.

Silver‑harmonized may integrate auxiliary Silver‑current streams, but
only through explicitly declared joins.

### Schema stability and evolution

Silver‑harmonized exposes a **canonical analytical schema**.

This schema is expected to evolve over time, but under strict rules: -
existing columns must not be renamed or removed - semantic meaning of
existing columns must not change - new columns may be added

Schema evolution is versioned and deliberate.

### Column semantics and roles

Silver‑harmonized may assign **semantic roles** to selected columns
(e.g. entity identifier, event start, event end).

Semantic roles are optional and stream‑specific. Only a stable entity
identifier is mandatory.

Roles are declarative metadata and do not impose computation or
filtering by themselves.

### Transformations

Silver‑harmonized may apply:

-   column renaming
-   type normalization
-   light derivations
-   controlled joins

Transformations must be deterministic and explicitly specified.

Silver‑harmonized must not:

-   infer version validity
-   reinterpret stream anchor semantics
-   apply business rules that change entity identity

### Temporal scope and persistence

Silver‑harmonized is typically persisted, but may cover a **limited
temporal window** (e.g. recent years only).

Unlike Silver‑current, Silver‑harmonized is not required to represent
full historical coverage.

### Guarantees provided by Silver‑harmonized

A valid Silver‑harmonized dataset guarantees:

-   method‑agnostic structure
-   stable analytical semantics
-   compatibility with downstream indicators
-   insulation of analysis from ingestion mechanics

### What Silver‑harmonized does not guarantee

Silver‑harmonized does not guarantee:

-   completeness across all historical time
-   correctness of domain interpretation beyond declared transformations
-   immutability of future schema extensions

Those responsibilities belong to governance and Gold layers.
