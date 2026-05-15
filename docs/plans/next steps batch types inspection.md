---
title: "next steps batch types inspection"
output: html_document
---

# Next Steps — Batch Type Contracts, Inspection, and Silver Configuration

## Status

The DuckDB migration has been merged into `main`.

Bronze now uses one DuckDB database per stream, with one table per
`stream_id + method_id + source_table` and an authoritative
`__promotion_log` inside the same database. This implements the core
migration goal: atomic Bronze promotion with no split-brain between data
files and promotion state.

Silver-current has also been implemented as a DuckDB-native table family
inside `data/silver/<stream_id>.duckdb`.

Currentness is defined by ingestion order:

``` sql
ORDER BY __batch_created_at DESC, __batch_id DESC
```

Secondary Silver-current tables are filtered by joining to the current
anchor table using:

``` text
identity_keys + __batch_id
```

This reflects the actual source semantics: the latest valid version of
an entity is the latest imported batch containing that entity. Domain
anchor time is not used to determine currentness.

## Scope of this branch

This branch focuses on making the existing Batch → Bronze →
Silver-current pipeline stricter, more inspectable, and easier to
operate.

In scope:

-   Batch column type enforcement
-   Batch inspection improvements
-   Bronze inspection helper
-   Silver-current inspection polish
-   Silver configuration contract for canonical method selection
-   Public Silver-current promotion wrapper
-   XML extractor profile refactor for SDO and future XML families

Out of scope:

-   Harmonized Silver
-   Fiscal/year semantic enrichment
-   Export formats for external consumers
-   Advanced schema migration tooling
-   Incremental Silver rebuilds
-   Full contract cleanup of the legacy `components` field

Harmonization will be designed in a later branch.

## Why this branch is needed

The DuckDB migration solved the storage and transaction problem, but
real batches exposed a separate class of issues:

1.  Some semantically coded fields can be parsed or written as numeric
    values, destroying leading-zero information.
2.  Batch may produce technically invalid artifacts, such as zero-column
    Parquet files.
3.  Bronze now has real state and therefore needs a proper inspection
    helper.
4.  Silver-current currently accepts `stream_id` and `method_id`
    directly, but production usage needs a declarative canonical method
    per stream.
5.  Adding another method for the same stream should not silently affect
    Silver-current.

The original migration plan correctly targeted DuckDB-native Bronze and
Silver storage, transaction-safe Bronze promotion, and Silver table
families inside one DuckDB file per stream. This branch builds on that
foundation without starting harmonization. The plan also explicitly
identified Bronze schema evolution and DuckDB-based inspection as
required follow-up work.

## Design decisions

### Abort philosophy (global rule)

The pipeline explicitly prefers **early aborts** over silently producing
partially valid or semantically corrupted data.

Any of the following conditions MUST cause an abort rather than a
warning:

-   Required tables (e.g. anchor_table) are missing
-   Declared identity keys are missing or NULL
-   Declared column types cannot be enforced safely
-   Incoming schema changes are incompatible (e.g. INTEGER → VARCHAR)
-   Batch artifacts are structurally invalid (e.g. zero-column Parquet)

Warnings are permitted only when the resulting data remains
unambiguously correct.

This philosophy applies uniformly across Batch, Bronze, and Silver.

### 1. Batch is responsible for semantic column types

Bronze should preserve the schema it receives from Batch. It should not
be responsible for repairing semantically wrong types.

If a code such as `075` becomes numeric `75`, the information has
already been lost before Bronze. The fix belongs at extraction time or
immediately before writing Batch Parquet.

Rule:

> If formatting carries meaning, the column is character, not numeric.

Examples:

-   DRG codes
-   ICD diagnosis codes
-   procedure/intervention codes
-   ward or administrative codes that may contain leading zeros
-   identifiers that look numeric but are not measures

### 2. Bronze handles schema evolution, not semantic correction

Bronze should continue to handle additive schema evolution:

-   New incoming columns are added to the Bronze table.
-   Missing incoming columns are inserted as `NULL` using name-based
    insert.
-   Column order changes are harmless.

Bronze should not silently coerce semantic code columns after they were
written incorrectly to Parquet.

### 3. Silver-current uses a canonical method per stream

Bronze may contain multiple methods for the same stream because
different methods may have incompatible schemas. This is already encoded
in the Bronze table naming convention:

``` text
{stream_id}__{method_id}__{source_table_name}
```

Silver-current must not automatically merge or choose among methods.

Each stream should declare one canonical method for Silver-current. If
multiple methods exist and no canonical method is declared, Silver
promotion should abort rather than guessing.

### 4. Silver-current rebuilds the table family

Silver-current should be rebuilt as a full table family for the selected
stream and canonical method.

That means:

``` text
current__anchor_table
current__secondary_table_1
current__secondary_table_2
...
```

are created or replaced together.

Silver-current should not append and should not mix methods.

### 5. Harmonized Silver stays in the same DuckDB file later

When harmonization is implemented, it should live in the same stream
DuckDB file as Silver-current:

``` text
data/silver/sdo.duckdb
  current__ricovero
  current__diagnosi
  current__procedure
  harmonized__ricovero
  harmonized__diagnosi
  harmonized__procedure
```

This matches the DuckDB migration plan’s Silver layout and keeps one
inspection surface per stream. Parquet export, if needed, should be an
external export step, not the canonical Silver storage.

Harmonization itself is out of scope for this branch.

## Work package 1 — Batch type contract

### Goal

Prevent semantic information loss before Parquet is written.

### Proposed contract extension

Add method-level type rules to `methods.json`.

Preferred shape:

``` json
{
  "xml_campania_2026": {
    "schema_domain": "sdo",
    "type": "xml",
    "input_type": "directory",
    "anchor_table": "ricovero",
    "identity_keys": ["codiceIstitutoDiCura", "progressivoSDO"],
    "partition_column": "dataDimissione",
    "column_types": {
      "ricovero": {
        "DRG": "character"
      },
      "diagnosi": {
        "diagnosiDimissione": "character",
        "presenteAlRicovero": "character"
      },
      "procedure": {
        "intervento": "character",
        "interventoEsterno": "character",
        "UDI": "character"
      },
      "trasferimenti": {
        "unitaTrasferimento": "character"
      },
      "accessi_dh": {
        "codiceIstitutoDiCura": "character",
        "progressivoSDO": "character"
      }
    }
  }
}
```
List-columns are not currently handled by `column_types`.

For example, repeated surgeon or anesthetist values inside procedure
rows are preserved as list-columns by the XML parser and must not be
declared as `"character"` until list-column type enforcement is
explicitly supported.

The exact column names should be aligned with the actual extractor
output.

### Implementation tasks

Call the helper inside Batch materialization after privacy rules and
before Parquet writing.

Ensure character coercion preserves leading zeros when the source value
was parsed as character.

For columns already parsed as numeric, document that leading zeros
cannot be recovered and the extractor must be corrected upstream.

Abort Batch materialization if a column declared in column_types cannot
be coerced to the requested type without loss of information. Silent
fallback or best-effort coercion is not allowed.

### Acceptance checks

-   A code value `"075"` remains `"075"` in Batch Parquet.
-   DuckDB reads the column as `VARCHAR`.
-   Bronze preserves the column as text.
-   Silver-current preserves the value unchanged.
-   Batch materialization aborts if a declared character/code column
    cannot be enforced due to incompatible inferred type.

## Work package 1a — XML extractor profiles and normalization

### Goal

Refactor the XML extraction tool to support multiple XML families (SDO,
EMUR, FileCInt) in a structured and extensible way, while keeping
parsing logic code‑driven and preserving the current performance and
simplicity guarantees.

This work package enables Batch type enforcement and artifact validation
to operate consistently across different XML schemas without duplicating
extraction orchestration logic.

### Scope and constraints

The XML extractor must remain code‑driven, not configuration‑driven.

methods.json is allowed to select which XML parsing profile to use, but
must not attempt to describe full XML parsing logic (nodes, attributes,
repetitions, joins) declaratively.

XPath, enrichment, harmonization, and semantic interpretation remain out
of scope for the extractor.

### Design decision

Introduce the concept of XML profiles.

An XML profile is a named parsing strategy implemented in code,
responsible for extracting one XML family into a set of batch‑ready
tables. Examples of profiles:

-   sdo_tracciato_abcd
-   emur_v1
-   filecint_v1

Each method declares the XML profile it uses.

### Contract change (methods.json)

Add an xml_profile field to XML methods.

Example:

``` json
"xml_campania_2026": {
  "schema_domain": "sdo",
  "type": "xml",
  "xml_profile": "sdo_tracciato_abcd",
  "anchor_table": "ricovero",
  "identity_keys": ["codiceIstitutoDiCura", "progressivoSDO"]
}
```

The xml_profile value is used only to select the parsing function.

### Extractor refactoring

extract_xml(ctx) becomes a thin dispatcher:

-   resolve input XML files (already implemented)
-   select the parser function based on xml_profile
-   apply the parser to each XML document
-   merge results by table name across multiple files
-   return a named list of data.frames

No schema logic, type enforcement, or validation happens here.

### XML Profile registry

Introduce an internal registry mapping profile names to parser
functions:

``` r
.xml_profile_registry <- list(
  sdo_tracciato_abcd = .xml_profile_sdo_tracciato_abcd,
  emur_v1          = .xml_profile_emur_v1,
  filecint_v1      = .xml_profile_filecint_v1
)
```

Each profile function has the signature:

``` r
function(doc, path, ctx) -> list(table_name = data.frame, ...)
```

### Profile implementation rules

Each XML profile:

-   owns all XML‑specific parsing logic for its schema family
-   may define helper functions internally (e.g. per‑record context
    builders)
-   returns flat, relational tables
-   may preserve multi-valued scalar nodes as list-columns when they are
    attributes of the same logical row
-   does not perform:
    -   type coercion
    -   enrichment
    -   validation beyond minimal structural safety
    -   cross‑table joins


For example, repeated surgeon or anesthetist nodes inside one procedure
row are stored as list-columns, not as separate tables. In contrast,
`Trasferimenti` is a true 1-N event structure and is extracted as a
separate table.

Shared helpers must be strictly mechanical; any domain-specific logic
must remain profile-local to avoid hidden coupling between XML families.

### Normalization boundary

All normalization happens after extraction and before Parquet writing,
not inside XML parsing. Specifically, the following steps must occur in
Batch materialization, not in the extractor:

-   column type enforcement from methods.json
-   required vs optional table checks
-   zero‑column table detection
-   batch artifact validation

The extractor’s responsibility ends once syntactically valid tables are
produced.

### Required vs optional tables

Each method must clearly distinguish required tables from optional ones.

Rules:

-   The table declared as anchor_table is always required.
-   Secondary tables are optional unless explicitly stated otherwise.
-   Absence of a required table must cause Batch or Bronze promotion to
    abort.
-   Absence of optional tables must be handled without creating empty or
    invalid artifacts.

This distinction must be enforced outside the extractor, during Batch
materialization.

### Acceptance checks

-   Existing SDO extraction is migrated into the `sdo_tracciato_abcd`
    profile.
-   SDO Tracciato B produces the expected table family:
    `ricovero`, `diagnosi`, `procedure`, `trasferimenti`, and
    `accessi_dh` when present.
-   The `trasferimenti` table is extracted as a true 1-N table with
    `codiceIstitutoDiCura`, `progressivoSDO`, `numTrasferimento`,
    `dataTrasferimento`, `oraTrasferimento`, and `unitaTrasferimento`.
-   extract_xml() no longer contains SDO‑specific logic.
-   Adding EMUR or FileCInt extraction requires:
    -   implementing a new profile function
    -   registering it in the profile registry
    -   declaring xml_profile in methods.json
-   No XPath usage or tidyverse reintroduction occurs.
-   Performance characteristics of the current SDO extractor are
    preserved.

### Explicit non‑goals

This work package does not implement:

-   semantic harmonization
-   domain interpretation
-   fiscal year logic
-   code system mapping
-   cross‑profile unification

Those belong to later Silver harmonization work.


### Note on legacy components field 

The `components` field is currently overloaded.

For XML directory methods, it is used to resolve physical input files into
`ctx$resolved_inputs`.

For Access/MDB methods, it is used as the list of source tables to
extract.

This branch does not refactor `components`. The field is retained for
compatibility. A future contract cleanup may split it into:

- `input_components`
- `source_tables`
- `output_tables`

No current implementation should assume that `components` means output
tables for all method types.

During this branch, `components` must be treated as a legacy compatibility
field. New XML profile work should not add new semantic meaning to it.

## Work package 2 — Batch artifact validation

### Goal

Prevent invalid Batch artifacts from entering Bronze.

### Rules

Batch should not write Parquet files with zero columns.

A table with zero rows but a valid schema is acceptable.

A table with zero columns is not a dataset and should either:

-   not be written at all; or
-   cause Batch materialization to abort if the table is required.

### Implementation tasks

In `.persist_to_batch()`, skip zero-column optional tables.

Add a clear warning:

``` text
Not writing "<table>": extracted table has zero columns.
```

Define required tables:

-   The method `anchor_table` is always required.
-   Optional secondary tables may be absent.

Abort Batch or Bronze promotion if the anchor table is absent.

`_batch_metadata.json` is descriptive, not authoritative.

The presence of Parquet files on disk defines the set of materialized
tables. Metadata entries for tables that were not materialized must be
treated as informational only and must not drive Bronze promotion logic.

### Acceptance checks

-   Mini-batches without optional `accessi_dh` do not write invalid
    `accessi_dh.parquet`.
-   Bronze promotion succeeds without optional tables.
-   Bronze promotion aborts if the anchor table is missing.

## Work package 3 — Inspect Batch layer

### Goal

Upgrade `inspect_batch_layer()` so it detects common artifact problems
before Bronze promotion.

### Inspection should report

For each batch:

-   batch id
-   stream id
-   method id
-   creation time
-   input path
-   materialized Parquet tables
-   metadata-listed components
-   missing expected anchor table
-   zero-column Parquet files
-   row counts per Parquet table
-   column counts per Parquet table
-   suspicious types for declared code columns

### Suggested public API

``` r
inspect_batch_layer(config = get_xpipe_config())
```

Keep the existing function name and improve the returned object and
print method.

### Acceptance checks

-   Incomplete batches are clearly reported.
-   Zero-column Parquet files are flagged.
-   Missing anchor table is flagged.
-   Row counts and table schemas are visible from console output.

## Work package 4 — Inspect Bronze layer

### Goal

Create a DuckDB-native Bronze inspection helper.

The migration plan explicitly required replacing filesystem-based Bronze
inspection with DuckDB table inspection, row counts, and promotion log
queries.

### Proposed public API

``` r
inspect_bronze <- function(
  stream_id,
  config = get_xpipe_config(),
  read_only = TRUE
)
```

### Inspection should report

-   Bronze DuckDB path
-   all tables
-   data tables only
-   row count per data table
-   `__promotion_log` entries
-   latest promoted batch
-   promoted batches per method
-   tables listed in `__promotion_log`
-   physical tables not referenced by the log
-   log-referenced tables missing physically
-   schema summaries per table

### Acceptance checks

-   Inspection opens `data/bronze/<stream_id>.duckdb`.
-   It shows promoted batches from `__promotion_log`.
-   It shows row counts for each Bronze data table.
-   It detects log/data inconsistencies.

## Work package 5 — Silver configuration contract

### Goal

Move canonical Silver-current method selection out of function arguments
and into a declarative contract.

### Proposed file

``` text
data/shared/silver.json
```

or package asset equivalent, depending on how other contracts are
stored.

### Proposed structure

``` json
{
  "_meta": {
    "type": "silver_contract",
    "version": "0.1.0"
  },
  "streams": {
    "sdo": {
      "canonical_method": "xml_campania_2026",
      "current": {
        "enabled": true
      },
      "harmonized": {
        "enabled": false
      }
    }
  }
}
```

Harmonized settings are included only as placeholders for future work.

No harmonization logic should be implemented in this branch.

### Implementation tasks

-   Add `silver.schema.json`.
-   Add `.load_silver_contract()` to configuration loading.
-   Store the parsed contract in `config$silver`.
-   Validate that each `canonical_method` exists in `config$methods`.
-   Validate that canonical method schema domain matches the stream.
-   Make Silver-current promotion resolve `method_id` from
    `config$silver` by default.

### Acceptance checks

-   `load_xpipe_config()` loads and validates `silver.json`.
-   Missing canonical method aborts during config load.
-   Invalid stream/method pairing aborts during config load.
-   Silver-current can be promoted by stream alone.

## Work package 6 — Public Silver promotion API

### Goal

Add a public wrapper around the internal Silver-current function.

### Proposed API

``` r
promote_to_silver <- function(
  config = get_xpipe_config(),
  stream = NULL,
  phase = "current",
  dry_run = FALSE,
  confirm = interactive()
)
```

### Behavior

For this branch:

-   only `phase = "current"` is supported
-   `phase = "harmonized"` aborts with a clear message
-   if `stream` is `NULL`, promote all enabled streams in `silver.json`
-   resolve canonical method from `config$silver`
-   rebuild current table family using `CREATE OR REPLACE TABLE`
-   optionally show dry-run preview

### Acceptance checks

-   `promote_to_silver(stream = "sdo")` works without passing method id.
-   If no canonical method is configured, promotion aborts.
-   If multiple Bronze methods exist, Silver still uses only the
    canonical method.
-   `phase = "harmonized"` aborts as not implemented.

## Work package 7 — Polish Silver-current inspection

### Goal

Keep `inspect_silver_current()` as the operational check for
Silver-current.

### Improvements

-   Use boxed console output consistently.
-   Report canonical method from `silver.json` once implemented.
-   Include Silver build metadata if `__silver_log` is added.
-   Keep returning structured data frames for programmatic use.

### Optional internal metadata table

Consider adding:

``` sql
CREATE TABLE IF NOT EXISTS __silver_log (
  phase TEXT,
  stream_id TEXT,
  method_id TEXT,
  built_at TIMESTAMP,
  source_bronze_db TEXT,
  tables TEXT
);
```

This is optional for this branch but useful.

## Not doing in this branch

Do not implement:

-   harmonized tables
-   mapping from local codes to standard vocabularies
-   fiscal year enrichment
-   derived epidemiological indicators
-   Parquet export
-   dashboard-facing marts
-   retention/pruning policies

Those belong after Batch typing, inspection, and canonical
Silver-current configuration are stable.

## Recommended implementation order

1.  Batch type contract
2.  XML extractor profiles and SDO parser normalization
3.  Batch artifact validation
4.  Inspect Batch layer upgrade
5.  Inspect Bronze layer
6.  Silver contract loader
7.  Public `promote_to_silver()` wrapper
8.  Silver inspection polish

This order is intentional. Type correctness and extractor structure come
before artifact validation because downstream validation must operate on
stable, profile-driven Batch outputs.

## Operational rule: inspection before promotion

Batch and Bronze inspection are considered mandatory operational steps.

Before promoting: 

- Batch → Bronze: `inspect_batch_layer()` must show no structural errors.
- Bronze → Silver: `inspect_bronze()` must show no log/data inconsistencies.


Skipping inspection is acceptable only in automated pipelines that
perform equivalent validation programmatically.

## Definition of done

This branch is complete when:

-   Batch can enforce declared character/code columns before Parquet
    writing.
-   Batch no longer writes zero-column Parquet files.
-   Batch inspection clearly reports artifact validity.
-   Bronze inspection clearly reports DuckDB state and promotion
    history.
-   Silver-current method selection is driven by `silver.json`.
-   `promote_to_silver(stream = "sdo")` works without a method argument.
-   `inspect_silver_current()` remains usable and shows canonical method
    state.
-   No harmonization logic has been added.
-   Batch aborts on unenforceable type declarations.
-   Inspection helpers are sufficient to detect all previously observed
    real-world failure modes without manual DuckDB queries.
-   XML extraction is profile-driven through `xml_profile`.
-   `extract_xml()` no longer contains SDO-specific branching logic.
-   The SDO XML profile produces the complete expected SDO table family,
    including `trasferimenti`.
-   Repeated surgeon/anesthetist nodes in procedure rows are preserved
    without data loss.

---

## Backlog for future plans

This section records relevant design notes and implementation ideas that
emerged during this branch but are explicitly out of scope for the
current plan.

Items listed here are **not acceptance criteria** for this branch. They
are candidates for future planning documents.

---

### Contract cleanup

The `components` field is currently overloaded and should eventually be
split into clearer contract fields.

Potential future structure:

```json
{
  "input_components": {
    "A": "*_A.xml",
    "B": "*_B.xml"
  },
  "source_tables": ["..."],
  "output_tables": ["..."]
}
```

Possible meanings:

- **input_components**  
  Physical input files or file patterns to resolve before extraction.

- **source_tables**  
  Source tables to extract from database-like inputs such as Access/MDB.

- **output_tables**  
  Logical tables expected from the extractor.

This cleanup should be handled in a dedicated contract-refactor branch
because it affects Batch preparation, XML extraction, Access extraction,
metadata, recap output, and inspection.

---

### XML extractor expansion

Future XML profiles should be added without changing `extract_xml()`.

Planned or likely profiles include:

- `emur_v1`
- `filecint_v1`
- future extensions of `sdo_tracciato_abcd`

Each new profile should:

- be implemented as a separate code-driven parser function
- be registered in `.xml_profile_registry`
- be selected via `xml_profile` in `methods.json`
- return a named list of flat, batch-ready `data.frame`s
- avoid XPath, enrichment, harmonization, and cross-table semantic joins

---

### EMUR extraction

EMUR will likely require its own XML profile.

Known expected characteristics:

- input may be split into anagrafica and sanitary components
- some structures may resemble SDO, including repeated procedure-like
  sections
- profile-local parsing logic should be preferred over shared
  domain-specific helpers

Shared helpers may be used only when they are purely mechanical.

---

### FileCInt extraction

FileCInt should be handled as a separate XML profile if XML-based, or as a
separate extractor type if the format requires different mechanics.

The decision should be made only after inspecting real input structure.

Expected concerns:

- high row volume
- strict type preservation
- avoiding unnecessary R materialization where possible
- clear distinction between source records and derived analytical tables

---

### Harmonized Silver

Harmonized Silver is intentionally out of scope for this branch.

Future harmonization work may include:

- standardizing column names across methods
- parsing and validating dates
- deriving fiscal or reporting years
- mapping local codes to controlled vocabularies
- producing epidemiology-ready semantic tables
- deciding whether list-columns should be exploded or preserved
- creating export views or Parquet exports for external consumers

Harmonized tables should initially live in the same stream DuckDB file as
Silver-current:

```text
data/silver/<stream_id>.duckdb
  current__*
  harmonized__*
```

Parquet should remain an export format, not the canonical Silver storage.

---

### Date parsing and temporal semantics

Dates currently remain strings in Batch, Bronze, and Silver-current when
source formats are not guaranteed to be clean and stable.

Future harmonization may parse dates into typed date/timestamp columns.

Parsing should be explicit and audited. Silent conversion to `NA` must be
avoided.

---

### Privacy rule expansion

Some additional fields may require pseudonymization or removal, such as
surgeon or anesthetist identifiers.

This should be handled through the privacy contract, not through Batch
type enforcement or XML parsing.

Future work should review:

- `chirurgoIntervento`
- `anestesistaIntervento`
- any other operator/person identifiers introduced by new profiles

---

### Bronze schema evolution hardening

Current Bronze schema evolution handles additive schema changes.

Future work may extend this to:

- type widening
- explicit incompatible type-change aborts
- schema evolution reporting in `inspect_bronze()`
- manual migration utilities for rare incompatible changes

---

### Layer metadata

Bronze and Silver may receive descriptive `layer.json` files similar to
Batch, but without `expected_hash`.

These files should be descriptive only.

Authoritative state remains:

- **Batch**: immutable batch directories and metadata
- **Bronze**: `__promotion_log` inside DuckDB
- **Silver**: Silver contract plus generated DuckDB tables

---

### Retention and pruning

Retention policies are not needed now.

Future work may define pruning or archival rules, for example keeping only
recent years in Bronze while preserving rebuildability from Batch.

Retention must be treated as a deliberate operational policy, not as a
hidden side effect of promotion.

