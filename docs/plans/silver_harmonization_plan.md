---
date: 2026-05-22
---

# Next steps — Silver-harmonized implementation

## Status

The Batch → Bronze → Silver-current control plane is complete.

The system currently provides:

-   immutable Batch materialization
-   DuckDB-native Bronze with authoritative `__promotion_log`
-   DuckDB-native Silver-current inside `data/silver/<stream_id>.duckdb`
-   canonical Silver-current method selection through `silver.json`
-   optional Silver-current ingestion snapshot rebuild through `as_of`
-   shape-aware privacy rules applied in Batch before Parquet writing
-   explicit inspection for Batch, Bronze, and Silver-current

Silver-current already defines currentness by ingestion order:

``` sql
ORDER BY __batch_created_at DESC, __batch_id DESC
```

Secondary Silver-current tables are filtered by joining to the selected
current anchor table using:

``` text
identity_keys + __batch_id
```

Silver-harmonized will build on this state. It must not redefine
currentness, read Bronze directly, or choose among methods. Those
responsibilities already belong to Silver-current and the Silver
configuration contract.

------------------------------------------------------------------------

## Scope of this branch

### In scope

-   Extend `silver.json` to configure Silver-harmonized
-   Add harmonization profile selection
-   Add a minimal code-driven SDO harmonization profile
-   Persist `harmonized__*` tables in the same stream Silver DuckDB
-   Extend `promote_to_silver()` with:
    -   `phase = "all"` as default
    -   `phase = "current"`
    -   `phase = "harmonized"`
-   Add Silver build metadata through `__silver_log`
-   Add basic inspection support for current/harmonized alignment

### Out of scope

-   Gold-layer indicators
-   dashboard marts
-   export formats
-   complex semantic mappings
-   vocabulary standardization
-   fiscal year enrichment
-   cross-stream integration
-   generic declarative transformation DSL

------------------------------------------------------------------------

## Design principles

### Same Silver DuckDB, new table family

Silver-harmonized lives in the same stream DuckDB database as
Silver-current.

Physical layout:

``` text
data/silver/<stream_id>.duckdb
  current__<source_table_name>
  harmonized__<table_name>
```

Example:

``` text
data/silver/sdo.duckdb
  current__ricovero
  current__diagnosi
  current__procedure
  harmonized__ricoveri
  harmonized__diagnosi
  harmonized__procedure
```

No separate harmonized database is created.

### Silver-harmonized derives only from Silver-current

Silver-harmonized reads only `current__*` tables.

It must not:

-   read Bronze directly
-   inspect the Bronze `__promotion_log`
-   re-evaluate currentness
-   choose among methods
-   mix methods

All currentness, canonical method, and `as_of` decisions are inherited
from Silver-current.

### Harmonized preserves the current table family

Silver-harmonized preserves the Silver-current table family.

Every relevant `current__*` table is promoted to a corresponding
`harmonized__*` table, unless explicitly excluded by contract.

Some harmonized tables may be enriched through code-driven
transformations. For example, `harmonized__ricoveri` may intentionally
duplicate selected diagnosis and procedure information to support common
analytical workflows.

This duplication does not replace the detailed harmonized tables.
Detailed tables such as `harmonized__diagnosi` and
`harmonized__procedure` remain available for row-level analyses.

### `promote_to_silver()` remains the single public API

No new public wrapper is introduced.

The public API remains:

``` r
promote_to_silver(
  config = get_xpipe_config(),
  stream = NULL,
  phase = "all",
  as_of = NULL,
  dry_run = FALSE,
  confirm = interactive()
)
```

Supported phases:

``` text
phase = "all"
phase = "current"
phase = "harmonized"
```

Semantics:

``` text
phase = "all"
  rebuild current__* first
  rebuild harmonized__* second, if harmonized.enabled = true
  uses the same as_of for both phases

phase = "current"
  rebuild current__* only
  may make existing harmonized__* tables stale

phase = "harmonized"
  rebuild harmonized__* only from existing current__* tables
  must verify current compatibility with requested as_of
```

`phase = "all"` is the default operational mode.

------------------------------------------------------------------------

## Normalization is declarative; transformation is code-driven

`silver.json` declares:

-   whether harmonization is enabled
-   harmonization profile selection
-   harmonized table names
-   final column names
-   mapping from intermediate columns to final names

It does **not** describe complex semantic transformations as a
mini-language.

Transformations are implemented in code through registered harmonization
profiles, similarly to XML parsing profiles.

This avoids building a fragile JSON DSL that would still require
profile-specific code to interpret correctly.

Columns not explicitly listed in the harmonized column mapping are
propagated unchanged.

------------------------------------------------------------------------

## Proposed `silver.json` shape

Example:

``` json
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
          "ricoveri": {
            "source": "ricovero",
            "columns": {
              "codice_istituto": "codiceIstitutoDiCura",
              "progressivo_sdo": "progressivoSDO",
              "identificativo_paziente": "identificativo_paziente",
              "diagnosi_principale": "diagnosi_principale",
              "diagnosi_secondarie": "diagnosi_secondarie",
              "procedura_principale": "procedura_principale",
              "tutte_le_procedure": "tutte_le_procedure"
            }
          }
        }
      }
    }
  }
}
```

Notes:

-   `profile` selects code-driven harmonization logic
-   `tables` declares the final harmonized table family
-   `columns` declares final names and expected intermediate columns.
    The absence of a column in `silver.json` does not imply that the
    source table is not promoted; it only means the column is not part
    of the harmonized analytical schema.
-   derived or intermediate columns are produced by the harmonization
    profile before final normalization

------------------------------------------------------------------------

## Work package 1 — Silver contract extension

### Goal

Extend `silver.json` and its schema to support Silver-harmonized
configuration.

### Tasks

-   Update `silver_contract.schema.json`
-   Allow `harmonized.enabled`
-   Add optional `harmonized.profile`
-   Add optional `harmonized.tables`
-   If `harmonized.enabled = true`, require:
    -   `profile`
    -   at least one harmonized table
-   Keep `current.enabled` unchanged
-   Keep `canonical_method` unchanged

### Acceptance checks

-   `load_xpipe_config()` accepts current-only streams
-   `load_xpipe_config()` accepts harmonized-enabled streams with a
    valid profile and tables
-   `load_xpipe_config()` aborts if `harmonized.enabled = true` but
    `profile` is missing
-   `load_xpipe_config()` aborts if `harmonized.enabled = true` but no
    harmonized tables are declared

------------------------------------------------------------------------

## Work package 2 — Harmonization profile registry

### Goal

Introduce code-driven harmonization profiles.

### Proposed internal registry

``` r
.silver_harmonized_profile_registry <- list(
  sdo_harmonized_v1 = .silver_profile_sdo_harmonized_v1
)
```

Each profile function has the signature:

``` r
function(con, stream_id, method_id, config)
```

The function may return a named list or write intermediate tables; the
exact return shape may be refined during implementation.

### Rules

A harmonization profile:

-   owns stream-specific transformation logic
-   reads only `current__*` tables
-   uses current legacy column names
-   produces intermediate analytical tables or columns
-   does not perform final naming normalization unless explicitly
    designed to do so
-   does not read Bronze
-   does not re-evaluate currentness

### Acceptance checks

-   unknown harmonization profile aborts
-   disabled harmonization does nothing
-   profile functions are internal and registered explicitly

------------------------------------------------------------------------

## Work package 3 — Minimal SDO harmonization profile

### Goal

Implement the first SDO harmonization profile.

The profile must promote the Silver-current table family into a
harmonized table family.

At minimum, each relevant `current__*` table should have a corresponding
`harmonized__*` table with normalized names and columns.

For SDO, the first analytical focus is:

``` text
harmonized__ricoveri
```

but this does not replace extended harmonized diagnosis and procedure
tables.

The expected table family includes at least:

``` text
harmonized__ricoveri
harmonized__diagnosi
harmonized__procedure
```

Additional tables such as transfers or day-hospital accesses may be
included as the profile matures.

### Input tables

The initial profile may use:

``` text
current__ricovero
current__diagnosi
current__procedure
current__anagrafica
```

If a source table required by the profile is missing, the profile must
abort unless the missing input is explicitly optional.

### Required output concept

The SDO harmonization profile should produce a harmonized table family,
not only one wide table.

`harmonized__ricoveri` is the main analysis-friendly table and should
include selected repeated information from related current tables.

It should include at least:

``` text
identificativo_paziente
diagnosi_principale
diagnosi_secondarie
procedura_principale
tutte_le_procedure
```

At the same time, detailed harmonized tables such as
`harmonized__diagnosi` and `harmonized__procedure` should remain
available for advanced analyses requiring row-level diagnosis or
procedure detail.

### Intended SDO semantics

``` text
diagnosi_principale
  diagnosis marked as principal

diagnosi_secondarie
  all diagnoses excluding the principal diagnosis

procedura_principale
  procedure marked as principal

tutte_le_procedure
  all procedures, including the principal procedure

identificativo_paziente
  patient code joined from current anagrafica or equivalent current
  source table
```

### Structural notes

-   `diagnosi_secondarie` may be a list-column
-   `tutte_le_procedure` may be a list-column
-   `tutte_le_procedure` includes the principal procedure
-   `diagnosi_secondarie` excludes the principal diagnosis

### Suggested internal transformation pipeline

``` r
.silver_profile_sdo_harmonized_v1 <- function(con, stream_id, method_id, config) {
  # 1. read current__ricovero
  # 2. add identificativo_paziente
  # 3. add diagnosi_principale / diagnosi_secondarie
  # 4. add procedura_principale / tutte_le_procedure
  # 5. apply normalization declared in silver.json
  # 6. write harmonized__ricoveri
}
```

Suggested helpers:

``` r
.add_identificativo_paziente_to_ricoveri()
.add_diagnosi_to_ricoveri()
.add_procedure_to_ricoveri()
.apply_harmonized_column_normalization()
```

These helpers operate on current legacy names before final
normalization.

### Acceptance checks

-   `harmonized__ricoveri` is created
-   the table is rebuilt using `CREATE OR REPLACE TABLE`
-   `diagnosi_principale` is scalar
-   `diagnosi_secondarie` excludes the principal diagnosis
-   `procedura_principale` is scalar
-   `tutte_le_procedure` includes the principal procedure
-   no Bronze table is read
-   currentness is inherited from `current__*`
-   Every relevant `current__*` source table is either promoted to a
    corresponding `harmonized__*` table or explicitly excluded by
    contract.
-   `harmonized__ricoveri` intentionally duplicates selected diagnosis
    and procedure information for common analyses.
-   `harmonized__diagnosi` remains available for detailed
    diagnosis-level analyses.
-   `harmonized__procedure` remains available for detailed
    procedure-level analyses.

------------------------------------------------------------------------

## Work package 4 — Silver build metadata

### Goal

Add `__silver_log` to track current and harmonized builds.

### Proposed table

``` sql
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

### Semantics

-   `__silver_log` records build metadata
-   it is not a source of domain truth
-   it is used to inspect whether `current__*` and `harmonized__*` are
    aligned

### Rules

-   current rebuild writes a `phase = "current"` entry
-   harmonized rebuild writes a `phase = "harmonized"` entry
-   `phase = "all"` produces both entries
-   `as_of` must be recorded as `NULL` or a normalized timestamp string
-   `source_tables` and `output_tables` are JSON strings

### Acceptance checks

-   `__silver_log` exists after Silver promotion
-   current builds are logged
-   harmonized builds are logged
-   inspection can compare latest current and harmonized build metadata

------------------------------------------------------------------------

## Work package 5 — Harmonized promotion engine

### Goal

Implement internal harmonized promotion.

### Proposed internal API

``` r
.promote_to_silver_harmonized <- function(
  stream_id,
  config,
  as_of = NULL
)
```

### Responsibilities

-   resolve canonical method
-   verify `harmonized.enabled`
-   resolve harmonization profile
-   open `data/silver/<stream_id>.duckdb`
-   verify required `current__*` tables exist
-   verify current state is compatible with requested `as_of`
-   run harmonization profile
-   write `harmonized__*` tables
-   write `__silver_log`

### Must abort if

-   harmonized is disabled
-   profile is missing
-   profile is unknown
-   required `current__*` table is missing
-   current state is incompatible with requested `as_of`
-   profile output does not contain declared intermediate columns
-   final normalization cannot be applied
-   output table has zero columns

### Acceptance checks

-   `phase = "harmonized"` rebuilds harmonized tables from existing
    current
-   it does not rebuild current
-   it aborts if current tables are missing
-   it aborts if current was built for a different `as_of`

------------------------------------------------------------------------

## Work package 6 — Extend `promote_to_silver()`

### Goal

Make `promote_to_silver()` orchestrate both Silver phases.

### Updated public API

``` r
promote_to_silver(
  config = get_xpipe_config(),
  stream = NULL,
  phase = "all",
  as_of = NULL,
  dry_run = FALSE,
  confirm = interactive()
)
```

### Phase behavior

``` text
phase = "current"
  run .promote_to_silver_current()

phase = "harmonized"
  run .promote_to_silver_harmonized()

phase = "all"
  run .promote_to_silver_current()
  then run .promote_to_silver_harmonized() if enabled
```

### Dry-run behavior

Dry-run should show:

-   stream
-   canonical method
-   requested phase
-   `as_of`
-   whether harmonized is enabled
-   output table families that would be rebuilt

### Acceptance checks

-   `promote_to_silver(stream = "sdo")` defaults to `phase = "all"`
-   `phase = "current"` rebuilds only `current__*`
-   `phase = "harmonized"` rebuilds only `harmonized__*`
-   `phase = "all"` rebuilds both in correct order
-   `as_of` is propagated consistently

------------------------------------------------------------------------

## Work package 7 — Inspection polish

### Goal

Extend Silver inspection to report current/harmonized alignment.

### Possible public API

Keep:

``` r
inspect_silver_current()
```

and consider adding later:

``` r
inspect_silver()
```

For this branch, a minimal update is sufficient.

### Inspection should report

-   latest current build from `__silver_log`
-   latest harmonized build from `__silver_log`
-   current `as_of`
-   harmonized `as_of`
-   alignment status:
    -   `ALIGNED`
    -   `STALE`
    -   `UNKNOWN`

Existing Silver-current status vs Bronze remains unchanged.

### Acceptance checks

-   if current was rebuilt after harmonized, inspection reports `STALE`
-   if both were rebuilt with the same `as_of`, inspection reports
    `ALIGNED`
-   if `__silver_log` is missing, inspection reports `UNKNOWN` rather
    than guessing

------------------------------------------------------------------------

## Explicit non-goals

This branch does not implement:

-   generic SQL DSL in `silver.json`
-   arbitrary joins declared in JSON
-   full vocabulary harmonization
-   fiscal year derivation
-   Gold indicators
-   export views
-   dashboards
-   retention policies

------------------------------------------------------------------------

## Definition of done

This branch is complete when:

-   `silver.json` supports harmonized configuration
-   `phase = "all"` is the default for `promote_to_silver()`
-   `phase = "current"` remains available for manual control
-   `phase = "harmonized"` rebuilds harmonized tables from current
    tables
-   harmonized tables are written as `harmonized__*` in the existing
    stream Silver DuckDB
-   a first SDO `harmonized__ricoveri` table is produced
-   `diagnosi_principale`, `diagnosi_secondarie`,
    `procedura_principale`, `tutte_le_procedure`, and
    `identificativo_paziente` are available in `harmonized__ricoveri`
-   transformations are code-driven through a registered harmonization
    profile
-   final naming normalization is driven by `silver.json`
-   `__silver_log` records current and harmonized builds
-   inspection can detect current/harmonized alignment or staleness
-   no harmonized logic reads Bronze directly
