# Pipeline Invariants

This document defines the non-negotiable invariants of the Batch →
Bronze → Silver pipeline.

These invariants describe **what must always be true** for the system to
be considered correct. They are independent of implementation details,
performance optimizations, or refactors.

If any invariant is violated, the pipeline is considered broken even if
it still executes without errors.

------------------------------------------------------------------------

## Global invariants

### G1. Abort is preferred over silent corruption

The pipeline must abort early rather than produce partially valid or
semantically corrupted data.

Warnings are acceptable only when the resulting data remains
unambiguously correct.

Silent fallback, best-effort coercion, or implicit recovery is forbidden
when semantic meaning may be altered.

### G2. Derived layers are rebuildable

Batch is immutable. Bronze and Silver are derived and must be fully
rebuildable from Batch.

No information required to rebuild Bronze or Silver may exist only in
runtime state or external systems.

------------------------------------------------------------------------

## Batch layer invariants

### B1. Batch is the semantic authority

Batch is responsible for preserving the semantic meaning of data.

If a value’s formatting carries meaning (e.g. leading zeros), that value
must be represented as character **before** Parquet writing.

Semantic meaning must not be repaired downstream.

### B2. Batch artifacts must be structurally valid

A Batch table must have: - a defined schema (≥ 1 column) - zero or more
rows

Parquet files with zero columns are invalid artifacts and must not be
written.

### B3. Required tables must exist

The table declared as `anchor_table` for a method is always required.

If the anchor table is missing: - Batch materialization must abort, or -
Bronze promotion must abort.

Optional tables may be absent without error.

### B4. Metadata is descriptive, not authoritative

`_batch_metadata.json` describes expected or configured components.

The presence of Parquet files on disk defines the set of materialized
tables.

Metadata entries for tables that were not materialized must not drive
promotion logic.

------------------------------------------------------------------------

## Bronze layer invariants

### R1. Bronze is append-only

Bronze tables are append-only.

Existing rows must never be updated, deleted, or overwritten.

### R2. Promotion is atomic

A Bronze promotion is atomic.

Either: - all data tables and the promotion log entry are committed,
or - nothing is committed.

Partial promotions are not allowed.

### R3. Promotion log is authoritative

`__promotion_log` inside the DuckDB database is the single source of
truth for promotion state.

If a batch is present in `__promotion_log`, it is promoted. If it is
absent, it is not promoted.

Filesystem state must not override the promotion log.

### R4. Schema evolution is additive or aborting

Bronze schema evolution rules:

-   New columns may be added.
-   Missing incoming columns result in NULLs.
-   Column reordering is harmless.
-   Incompatible type changes must cause an abort.

Silent type degradation is forbidden.

------------------------------------------------------------------------

## Silver layer invariants

### S1. Silver-current represents “latest batch containing the entity”

The canonical definition of “current” is:

> the row belonging to the latest imported batch that contains that
> entity.

Ordering is defined by:

``` sql
ORDER BY __batch_created_at DESC, __batch_id DESC
```

Anchor/domain time must not be used to determine currentness.

### S2. Silver-current uses a single canonical method per stream

For each stream, exactly one method is canonical for Silver-current.

If multiple methods exist and no canonical method is declared, Silver
promotion must abort.

Silver must never guess.

### S3. Silver-current is rebuilt, not appended

Silver-current tables are rebuilt as a consistent table family.

They must not:

-   append across runs
-   mix methods
-   retain partial state from previous builds

------------------------------------------------------------------------

## Inspection invariants

### I1. Inspection must detect known failure modes

Inspection helpers must be sufficient to detect all previously observed
real-world failure modes, including:

-   missing required tables
-   zero-column artifacts
-   schema drift
-   promotion log inconsistencies
-   orphan secondary rows in Silver

Manual DuckDB queries must not be required for routine validation.

### I2. Inspection precedes promotion

Before promoting Batch → Bronze, Batch inspection must show no
structural errors.

Before promoting Bronze → Silver, Bronze inspection must show no
log/data inconsistencies.

Skipping inspection is acceptable only in automated pipelines that
perform equivalent validation programmatically.

------------------------------------------------------------------------

## Change policy

Any change that violates an invariant requires:

-   an explicit discussion
-   an update to this document
-   a clear justification

Code changes that silently violate invariants are considered
regressions.
