---
date: 2026-05-22
---

# Privacy & PHI Contract

## Purpose

This document defines how the xpipe pipeline handles Protected Health
Information (PHI). It covers what constitutes PHI in this context, how
it is pseudonymized, what guarantees the system provides, and what the
operational constraints on that guarantee are.

This document is the authoritative reference for auditing, Data
Protection Officer review, and future development decisions involving
PHI.

## Core Principle

> PHI never touches disk.

Raw identifiers are processed entirely in memory. Pseudonymization
occurs in the Batch materialization pipeline — after extraction,
before any write to the filesystem. Every layer from Batch onwards
contains only pseudonymized identifiers or no identifiers at all.

## What Counts as PHI

In this pipeline, PHI is any column that can directly or indirectly
identify a patient, healthcare encounter, operator, or other protected
person.

The method configuration is the authoritative list.

Whether a column is PHI is a governance decision recorded in
`methods.json`, not inferred by the pipeline. The pipeline applies
privacy rules exactly where declared and nowhere else.

Privacy rules are declared per table, per column, and per data shape.


## Pseudonymization Method

### Algorithm

HMAC-SHA256, using the OpenSSL implementation (`openssl::sha256`).

### Key

A runtime-only secret called the **pepper key**, loaded from the
environment variable `XNE_PEPPER_KEY`. The pepper key:

- Is **never written to disk** — not in configuration files, not in
  metadata, not in logs
- Is **never embedded in any configuration file**
- Lives exclusively in the process environment for the duration of a
  pipeline session
- Must be set before `load_xpipe_config()` is called; absence is a
  hard abort with class `xpipe_runtime_pepper`

### Input normalization

Before hashing, each value is:

1. Cast to character
2. Stripped of leading and trailing whitespace (`trimws`)
3. Uppercased (`toupper`)

This makes the hash **case- and whitespace-insensitive**. The values
`"Mario Rossi"`, `"mario rossi"`, and `"  MARIO ROSSI  "` all produce
the same hash for the same pepper.

### Special values

- `NA` → returned as `NA_character_` (no hash computed)
- `""` (empty string) → returned as `NA_character_` (no hash computed)

Empty and missing values are never hashed and never written as a hash.

### Output

A lowercase hex-encoded string of 64 characters (256-bit hash, hex
representation). Example format:

```
3d7a8f2e1b9c4a0d...
```

## Determinism and Linkability

The hash is **deterministic**: the same input value with the same
pepper always produces the same output. This is intentional — it
allows downstream layers to join pseudonymized records across batches
without re-exposing the original identifier.

**Consequence**: anyone in possession of the pepper key can
reconstruct all hashes from known identifier values. The security of
the pseudonym depends entirely on the secrecy of the pepper key.

### Privacy Contract Shape

Privacy rules are declared under the optional `privacy` block of a
method definition.

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
`privacy.hash` pseudonymizes declared columns.
`privacy.skip` removes declared columns entirely.

Each rule is scoped by table name and column name. The value declares the
expected column shape:

- `scalar`: one value per row
- `list`: zero or more values per row, stored as a list-column

The declared shape is authoritative. If the extracted data shape does
not match the declared privacy shape, Batch materialization must abort.

## Where Privacy Rules Are Applied

Privacy rules are applied in `apply_privacy_rules()`, called during
Batch materialization while data is still in memory.

The sequence is:

1. extractor returns raw data frames
2. `privacy.skip` removes declared columns
3. `privacy.hash` pseudonymizes declared values
4. Batch column type enforcement runs
5. clean data frames are written to Batch Parquet

No raw PHI declared in `privacy` may pass into Parquet, Bronze, or Silver.

## Optional Privacy Block

The `privacy` block is optional.

If a method does not declare `privacy`, the pipeline performs no privacy
transformation for that method.

This is valid for streams that are already anonymized upstream or do not
require Batch-time privacy processing.

Absence of `privacy` is not an invalid method configuration.

## List-Column Privacy

Some protected identifiers may occur as list-columns.

For example, one procedure row may contain multiple surgeon or
anesthetist identifiers.

When a column is declared as `list`, hashing is applied element-wise and
the list structure is preserved.

The pipeline must not collapse, explode, reorder, or otherwise alter the
cardinality of list-column identifiers during privacy application.

## What Happens if the Pepper Key Changes

If `XNE_PEPPER_KEY` is rotated, **all previously generated hashes
become unlinked** from new hashes of the same original values. This
breaks cross-batch joins silently.

If the pepper key is changed, the entire pipeline must be re-ingested
from source with the new key. Existing Batch and Bronze layers
produced under the old key cannot be joined to layers produced under
the new key.

**Pepper rotation is a destructive, pipeline-wide operation** and must
be treated as such.

## Guarantees

The system guarantees:

- Declared raw PHI values are never written to any persisted pipeline
  layer.
- Privacy rules are applied uniformly to all declared table/column rules
  before Batch Parquet writing.
- `privacy.skip` removes declared columns before persistence.
- `privacy.hash` pseudonymizes declared scalar values and list elements
  deterministically.
- List-column privacy preserves list structure.
- Shape mismatches between declared privacy rules and extracted data
  abort Batch materialization.
- `NA` and empty values produce `NA_character_`, never a hash.
- The hash function and normalization are deterministic and stable across
  R sessions and platforms.
- The pepper key is never logged, serialized, or included in metadata.


## What the System Does NOT Guarantee

The system does not guarantee:

- The pepper key lifecycle, storage, rotation, or recovery.
- Correct PHI classification for undeclared columns.
- Protection for PHI columns not declared in `methods.json`.
- Linkability across pepper rotations.
- Re-identification resistance if the pepper key is leaked.
- Semantic interpretation of privacy fields beyond the declared
  table/column/action/shape contract.
