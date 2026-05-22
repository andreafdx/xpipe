# Next steps — Contract normalization and privacy rules

## Status

The Batch → Bronze → Silver-current control plane is complete and merged
into `main`.

The system now provides:

- strict Batch type enforcement
- artifact validation before Bronze promotion
- DuckDB-native Bronze with authoritative `__promotion_log`
- declarative Silver-current canonical method selection (`silver.json`)
- explicit promotion and inspection workflows
- operational inspection for Batch, Bronze, and Silver-current, including
  Bronze vs Silver currency status

This branch **does not extend the pipeline**.  
It focuses on **contract normalization and data governance**.

---

## Scope of this plan

### In scope

1. Contract cleanup of the legacy `components` field  
2. Declarative privacy rules, including support for list-columns  
3. Integration of privacy rules into Batch materialization  

### Out of scope

- Harmonized Silver
- Semantic enrichment
- Schema evolution tooling
- Incremental Silver rebuilds
- Export formats (Parquet, marts, dashboards)

This work targets **contracts and normalization boundaries**, not pipeline
mechanics.

---

## Motivation

Two structural issues remain after the DuckDB migration and control-plane
hardening.

### 1. Overloaded `components` contract field

The `components` field currently encodes multiple, unrelated concepts:

- physical input resolution for XML directory methods
- target tables for Access/MDB extractors
- indirect influence on operator-facing metadata and recap output

This overloading prevents clear validation and makes extractor behavior
hard to reason about and inspect.

### 2. Privacy handling for operator identifiers

Some identifiers requiring pseudonymization (e.g. surgeon or anesthetist
CFs):

- live inside list-columns
- are embedded within procedure rows
- cannot be handled by simple column type enforcement

Privacy rules must be:

- declarative and auditable
- explicit about data shape (scalar vs list)
- applied before Parquet writing
- independent from extraction mechanics

---

## Design principles

### Normalization boundary

**Batch is the last place where semantics may change.**

After Batch:

- Bronze preserves what it receives
- Silver preserves Bronze

Therefore:

- privacy transformations happen after extraction and before Parquet
  writing
- no privacy, type, or semantic repair is allowed downstream

### Separation of concerns

- input resolution is not extraction
- extraction is not validation
- validation is not privacy
- privacy is not harmonization

Each concern must have its own contract surface.

---

## Work package 1 — Contract cleanup (`components`)

### Goal

Replace the overloaded `components` field with explicit, single-purpose
fields.

### New contract fields

```json
{
  "input_files": {
    "file_a": "*_A.xml",
    "file_b": "*_B.xml"
  },
  "source_tables": ["..."],
  "output_tables": {
    "required": ["..."],
    "optional": ["..."]
  }
}
```

### Semantics

**input_files**  
Physical inputs or file patterns resolved during Batch preparation.

**source_tables**  
Logical source tables for database-like inputs (e.g. Access/MDB).

**output_tables**  
Tables expected from the extractor, used for validation and inspection
only. This field is informative in this branch.

### Rules

- XML methods must use `input_files`
- Database methods must use `source_tables`
- Extractors must not infer semantics from legacy `components`
- Batch preparation and extraction must prefer the new fields
- Legacy `components` remains temporarily supported as a fallback

### Non-goals

- No change in extractor behavior in this branch
- No harmonization of schemas or naming

---

## Work package 2 — Privacy contract

### Goal

Introduce declarative privacy rules applied during Batch materialization,
with explicit handling of scalar and list-columns.

### Privacy contract shape

```json
{
  "privacy": {
    "hash": {
      "procedure": {
        "chirurgoIntervento": "list",
        "anestesistaIntervento": "list"
      },
      "ricovero": {
        "identificativoPaziente": "scalar",
        "codiceFiscale": "scalar"
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

### Semantics

- rules are defined per table and column
- the declared shape (scalar or list) is authoritative
- the implementation must not infer shape at runtime

### Application rules

- privacy is applied after extraction and before Parquet writing
- `skip` removes columns entirely
- `hash` pseudonymizes values deterministically
- list-columns are transformed element-wise
- mismatches between declared and actual shape must abort Batch
  materialization

### Order of operations in Batch

1. `privacy.skip`
2. `privacy.hash`
3. `column_types` enforcement
4. artifact validation
5. Parquet writing

---

## Work package 3 — Batch integration

### Tasks

- integrate privacy application into Batch materialization
- ensure privacy runs before type enforcement
- update Batch inspection to surface privacy-applied schemas

### Acceptance checks

- operator identifiers are consistently pseudonymized
- list-columns are preserved structurally
- skipped columns never appear in Parquet
- Bronze and Silver never see raw identifiers
- Batch aborts on unenforceable privacy rules

---

## Explicit non-goals

This plan does not implement:

- harmonized Silver
- code system mapping
- fiscal year enrichment
- derived epidemiological indicators
- retention or pruning policies

These belong to future branches.

---

## Definition of done

This plan is complete when:

- `components` is no longer overloaded
- contracts explicitly distinguish inputs, sources, and expected outputs
- privacy rules are declarative, auditable, and shape-aware
- privacy applies correctly to scalar and list-columns
- Batch aborts on unenforceable privacy or contract mismatches
- Bronze and Silver require no changes

---

## Backlog notes (future work)

- harmonized Silver design
- schema evolution reporting
- expanded privacy rules
- operator role normalization
- export views and marts

These items are explicitly out of scope.
