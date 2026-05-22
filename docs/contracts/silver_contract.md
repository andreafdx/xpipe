title: "silver_contract" output: html_document editor_options: markdown: wrap: 72

# Silver — Contract Specification

This document defines the semantic contract of the Silver layer. Silver is the layer where raw ingested data is stabilized, versioned, and made usable for downstream interpretation and analysis.

Silver is composed of two sequential phases:

-   Silver‑current: version stabilization
-   Silver‑harmonized: analytical normalization

Each phase has distinct responsibilities and guarantees.

## Silver‑current

### Purpose and scope

Silver‑current represents the authoritative **current state** of a data stream, derived from the Bronze layer by applying an explicit, reproducible version‑selection rule.

It is the first layer in the pipeline that makes a **semantic claim** about the data:

> for each logical entity in the stream, this is the version that is considered valid at a given snapshot time.

Silver‑current does not perform analytical harmonization, cross‑stream integration, or domain interpretation beyond version validity.

### Canonical method selection

For each stream, Silver‑current is built from **one canonical ingestion method**, explicitly declared by configuration.

The canonical method defines:

- the identity keys of the entity
- the anchor (primary) table - the set of secondary tables 
- the structure of versioned data as ingested

If multiple ingestion methods exist for a stream, only the canonical one contributes to Silver‑current.

`__stream_id` and `__method_id` are the authoritative source of lineage information; filesystem layout must be consistent with them but is not semantically authoritative.

Canonicality is a policy decision, not a computed outcome.


### Entity identity

Each logical entity in the stream is uniquely identified by the set of `identity_keys` defined by the canonical method.

All rows sharing the same identity keys represent **different versions of the same entity**, never distinct entities.

This assumption is mandatory. If violated, Silver‑current is invalid.

### Versioning model

Data is versioned at the **entity level**.

Each ingestion produces a **complete version** of the entity, consisting of: - exactly one row in the anchor table - zero or more rows in each secondary table

All rows belonging to the same version share a common version identifier, such as a batch identifier or ingestion timestamp.

The specific technical marker is not prescribed by this contract, but **version consistency across tables is required**.

### Definition of “current”

For each entity (identity keys), the current version is defined as:

> the version whose ingestion time (or equivalent version marker) is the maximum value less than or equal to the requested snapshot time.

If no snapshot time is provided, the reference point is the time of execution.

The concept of “current” depends **only on ingestion order**, not on clinical dates, event dates, or stream anchor semantics.

### Anchor table behavior

Version selection is applied **exclusively to the anchor table**.

For each identity key: - exactly one anchor row is selected as current - that row determines the current version of the entity

The anchor table is the sole table that participates in version selection.

### Secondary table behavior

Secondary tables are **versioned together with the anchor**, but they do not participate in version selection.

Once the current version of an entity has been determined via the anchor table, secondary tables are filtered as follows:

> only rows belonging to the same version as the selected anchor row are retained.

Rows from older versions of the entity are excluded, even if they share the same identity keys.

There is no independent notion of “current row” within a secondary table.

### Relationship to stream temporal semantics

Silver‑current does **not** interpret the temporal meaning of the stream.

The stream‑level `anchor` property (e.g. start vs end) defines how events are assigned to institutional periods and is part of stream semantics, not versioning logic.

Silver‑current produces a dataset that is “current”, not “of a given period”.

### Persistence and physical layout

Silver‑current is **always persisted**.

Persistence is required because version selection is a semantic decision that must be: - reproducible - auditable - stable over time

Silver‑current may be physically partitioned (for example, by year) according to the stream configuration and canonical method partitioning rules.

Partitioning exists solely to support scalability, incremental rebuilds, and performance optimization.

Partitioning **does not affect** the semantic meaning of Silver‑current and must not be interpreted as a temporal filter or versioning rule.

## Silver‑harmonized

### Purpose and scope

Silver‑harmonized represents the **analytical form** of a stream, derived from Silver‑current by applying explicit normalization and enrichment rules.

Its purpose is to provide a **stable, method‑agnostic interface** for analysis, indicators, and downstream pipelines.

Silver‑harmonized does not redefine versioning logic and does not re‑evaluate “currentness”.

### Input and dependency

Silver‑harmonized is built **exclusively from Silver‑current**.

All versioning, deduplication, and entity selection decisions are inherited unchanged.

Silver‑harmonized may integrate auxiliary Silver‑current streams, but only through explicitly declared joins.

### Schema stability and evolution

Silver‑harmonized exposes a **canonical analytical schema**.

This schema is expected to evolve over time, but under strict rules: - existing columns must not be renamed or removed - semantic meaning of existing columns must not change - new columns may be added

Schema evolution is versioned and deliberate.

### Column semantics and roles

Silver‑harmonized may assign **semantic roles** to selected columns (e.g. entity identifier, event start, event end).

Semantic roles are optional and stream‑specific. Only a stable entity identifier is mandatory.

Roles are declarative metadata and do not impose computation or filtering by themselves.

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

Silver‑harmonized is typically persisted, but may cover a **limited temporal window** (e.g. recent years only).

Unlike Silver‑current, Silver‑harmonized is not required to represent full historical coverage.

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
