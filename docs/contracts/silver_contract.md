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

Inside the stream database, Silver-current tables are stored in a dedicated `current` schema:
```text
current.<source_table_name>
```
Example:

```text
data/silver/sdo.duckdb
  current.ricovero
  current.diagnosi
  current.procedure
```

Silver-current is rebuilt as a table family using `CREATE OR REPLACE TABLE`.

It must not append across runs, mix methods, or retain partial table
state from previous builds.

Physical partitioning is not part of the current Silver-current
contract. If introduced later, it must not alter the definition of
currentness.

## Silver-harmonized

Silver-harmonized represents the analytical form of a stream.

It is derived exclusively from Silver-current and lives in the same stream
DuckDB database alongside the `current` schema.

Silver-harmonized does not redefine currentness, does not read Bronze
directly, and does not choose among ingestion methods. All versioning,
canonical method selection, and ingestion snapshot decisions are inherited
from Silver-current.

---

## Purpose and scope

Silver-harmonized provides stable, analysis-oriented tables derived from
the current state of a stream.

Its role is to make the data easier to use for recurring analysis,
indicators, reporting, and downstream pipelines.

Silver-harmonized **may**:

- normalize table names
- normalize column names
- apply deterministic type normalization
- add small, explicitly implemented derived columns
- perform controlled joins among `current` schema tables
- reshape data where this improves common analytical use

Silver-harmonized **must not**:

- re-evaluate currentness
- read Bronze directly
- mix methods
- change entity identity
- apply opaque business rules
- silently infer transformations not declared by code or contract

---

## Physical layout

Silver-harmonized is persisted in the same DuckDB database as
Silver-current.

The physical layout is:

```text
data/silver/<stream_id>.duckdb
  current.<source_table_name>
  harmonized.<table_name>
```

Example:

```text
data/silver/sdo.duckdb
  current.ricovero
  current.diagnosi
  current.procedure
  harmonized.ricovero
```

Harmonized tables use the naming pattern:

```text
harmonized.<table_name>
```

Harmonized tables are rebuilt using `CREATE OR REPLACE TABLE`.

They must not append across runs and must not retain partial state from
previous builds.

---

## Dependency on Silver-current

Silver-harmonized is built **only** from `current` schema tables.

It must not read Bronze tables and must not inspect the Bronze promotion
log.

If Silver-current was built with an ingestion snapshot (`as_of`),
Silver-harmonized must be built from that same Silver-current state.

Silver-harmonized must never be more current than the `current` schema tables
from which it is derived.

---

## Promotion phases

`promote_to_silver()` is the public orchestration entry point for Silver.

The supported phases are:

```text
phase = "current"
phase = "harmonized"
phase = "all"
```

`phase = "all"` is the default operational mode.

It rebuilds Silver-current first and then Silver-harmonized, when
harmonization is enabled for the stream.

`phase = "current"` rebuilds only the `current` schema tables.  
This may make existing `harmonized` schema tables stale.

`phase = "harmonized"` rebuilds only the `harmonized` schema tables from
the existing `current` schema tables.

It must not read Bronze directly.

If `as_of` is provided with `phase = "all"`, the same ingestion snapshot
is used for both phases.

If `as_of` is provided with `phase = "harmonized"`, the existing
Silver-current state must be compatible with that snapshot. If alignment
cannot be verified, promotion must abort.

---

## Configuration

Silver-harmonized is configured in `data/shared/silver.json`.

The `harmonized` block declares whether harmonization is enabled and which
harmonization profile should be used.

Example:

```json
{
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

The JSON contract describes normalization and profile selection.

It does **not** describe complex semantic transformations as a declarative
mini-language.

---

## Normalization vs transformation

Silver-harmonized separates normalization from transformation.

**Normalization** is declarative and lives in `silver.json`.

Normalization includes:

- harmonized table names
- final column names
- inclusion of expected output columns
- mapping from intermediate column names to final analytical names

**Transformation** is code-driven and implemented in registered
harmonization profiles.

Transformations may include:

- joining `current` schema tables
- moving selected values from secondary tables into a main analytical
  table
- creating list-columns
- deriving convenience columns for frequent analysis

Transformation functions operate on Silver-harmonized column names
**after** final normalization is applied.

This allows profile-specific logic to reference clean, normalized names
instead of handling varying legacy field names.

---

## Harmonization profiles

Each stream may declare a harmonization profile.

A harmonization profile is a code-driven transformation strategy selected
by `silver.json`.

Example:

```json
{
  "harmonized": {
    "enabled": true,
    "profile": "sdo_harmonized_v1"
  }
}
```

The profile owns stream-specific transformation logic.

For SDO, the initial profile is expected to produce an enriched analytical
`harmonized.ricovero` table.

The registered profile functions are maintained inside the package's internal
registry, e.g., `.silver_profile_sdo_harmonized_v1` and `.silver_profile_emur_harmonized_v1`.

---

## SDO harmonized `ricovero` table

For the SDO stream, the primary harmonized analytical table is:

```text
harmonized.ricovero
```

It is derived from `current.ricovero` and enriched from other
`current` schema tables.

The SDO harmonized profile supports at least:

```text
identificativo_paziente
diagnosi_principale
diagnosi_secondarie
tutte_le_diagnosi
procedura_principale
tutte_le_procedure
```

The intended semantics are:

```text
diagnosi_principale
  diagnosis marked as principal

diagnosi_secondarie
  all diagnoses excluding the principal diagnosis

tutte_le_diagnosi
  all diagnoses, including the principal diagnosis

procedura_principale
  procedure marked as principal

tutte_le_procedure
  all procedures, including the principal procedure

identificativo_paziente
  patient identifier joined from the current anagrafica table
```

`diagnosi_secondarie` and `tutte_le_procedure` may be represented as
list-columns when this best preserves the analytical meaning.

---

## EMUR harmonized `ps` table

For the EMUR stream, the primary harmonized analytical table is:

```text
harmonized.ps
```

It is derived from `current.ps` and enriched from other `current` schema tables.

The EMUR harmonized profile (`emur_harmonized_v1`) supports:

```text
t0
t1
t2
t3
t4
t5
procedura_principale
tutte_le_procedure
codice_fiscale
sesso
data_nascita
luogo_residenza
asl_residenza
regione_residenza
problema_principale_obi
diagnosi_principale_uscita_obi
prestazione_principale_obi
data_ingresso_obi
ora_ingresso_obi
data_uscita_obi
ora_uscita_obi
esito_obi
```

The temporal columns represent normalized timestamps derived from date and time fields:
* `t0`: Entry timestamp (`data_entrata` + `ora_entrata`)
* `t1`: Triage/take charge timestamp (`data_presa_in_carico` + `ora_presa_in_carico`)
* `t2`: Examination timestamp (always NULL for v1)
* `t3`: Exit timestamp (`data_uscita` + `ora_uscita`)
* `t4`: OBI entry timestamp (`data_ingresso_obi` + `ora_ingresso_obi`)
* `t5`: OBI exit timestamp (`data_uscita_obi` + `ora_uscita_obi`)

---

## Build metadata

Silver may maintain an internal metadata table:

```sql
CREATE TABLE IF NOT EXISTS __silver_log (
  phase TEXT,
  stream_id TEXT,
  method_id TEXT,
  as_of TEXT,
  built_at TIMESTAMP,
  source_tables TEXT,
  output_tables TEXT
);
```

`__silver_log` records build metadata for Silver-current and
Silver-harmonized.

It is used to inspect whether `current` and `harmonized` schema tables
are aligned.

It is not a source of domain truth.

---

## Alignment and staleness

Silver-harmonized is **aligned** when it has been built from the current
Silver-current state for the same stream, canonical method, and ingestion
snapshot.

If `current` schema tables are rebuilt and `harmonized` schema tables are not
rebuilt afterwards, harmonized tables may be **stale**.

Inspection should be able to report whether Silver-current and
Silver-harmonized are aligned, stale, or unknown.

---

## Schema stability and evolution

Silver-harmonized exposes analytical schemas intended to be more stable
than source schemas.

Schema evolution is allowed but deliberate.

Existing harmonized columns should not be renamed or removed without a
contract change.

The semantic meaning of an existing harmonized column must not change
silently.

New columns may be added when needed for recurring analytical use.

---

## Guarantees provided by Silver-harmonized

A valid Silver-harmonized table family guarantees:

- it was built from Silver-current, not directly from Bronze
- it inherits currentness from Silver-current
- it uses the canonical method selected for the stream
- it applies deterministic, code-driven transformations
- it applies declarative normalization from `silver.json`
- it persists results in the `harmonized` schema in the stream Silver
  DuckDB database
- it does not silently redefine entity identity or currentness

---

## What Silver-harmonized does not guarantee

Silver-harmonized does not guarantee:

- completeness across all possible analytical use cases
- correctness of domain interpretation beyond declared transformations
- automatic synchronization if only `phase = "current"` is run
- immutability of future schema extensions
- Gold-layer indicators or dashboard-ready marts

Those responsibilities belong to governance, future Silver extensions, or
Gold-layer products.
