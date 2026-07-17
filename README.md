# xpipe

A personal Medallion data pipeline for processing health administrative
data (e.g., SDO, EMUR). The system structures data through three logical
layers: Batch (raw ingestion & privacy masking), Bronze (append-only
ledger in DuckDB), and Silver (entity resolution and stream
harmonization).

------------------------------------------------------------------------

## Install

Install and update via GitHub:

``` r
remotes::install_git("git@github.com:andreafdx/xpipe.git", ref = "v1.1.0")
# remove ref for latest commit
```

Once the install is complete, you can also run this command to install
any more recent commit:

``` r
remotes::update_packages("xpipe")
```

## Setup

The pipeline requires a cryptographic pepper key for pseudonymizing PHI.
Set this in your `.Renviron` file:

``` env
XNE_PEPPER_KEY=your_base64_pepper_key_here
```

To load the pipeline in R:

``` r
library(xpipe)

# Initialize the control plane and load configurations
load_xpipe_config()
```

------------------------------------------------------------------------

## Core Workflow

### 1. Ingestion (Batch Layer)

Processes a raw source file or folder from the configured `inbox`
directory. This step performs initial structural validation, applies
column type definitions, hashes sensitive patient identifiers using the
pepper key, and stores the output as immutable Parquet tables in
`data/batch/`.

``` r
batch_id <- ingest_batch(
  filename = "emur_2026_q1",             # File or folder name inside the inbox
  stream   = "emur",                     # Target stream: "emur" or "sdo"
  method   = "xml_emur_campania_2026"    # Extraction method defined in methods.json
)
```

### 2. Append-Only Ledger (Bronze Layer)

Promotes materialized batches from the Batch layer and appends their
rows into a stream-specific DuckDB database
(`data/bronze/<stream>.duckdb`). It tracks lineage and prevents
duplicate promotion.

``` r
promote_to_bronze(stream = "emur") # If stream is NULL, promotes all pending batches
```

### 3. Entity Resolution & Harmonization (Silver Layer)

Constructs the final analytical view by rebuilding two phases:

- **Current**: Resolves patient states by fetching the latest record per
  entity (based on `__batch_created_at` and identity keys).
- **Harmonized**: Applies schema mappings and custom aggregation
  profiles (e.g., merging demographics, diagnoses, and procedures) into
  cohesive analytical tables (like `harmonized__ps` or
  `harmonized__ricovero`).

``` r
# Promote both current and harmonized phases
promote_to_silver(stream = "emur", phase = "all")

# Or run specific phases
promote_to_silver(stream = "emur", phase = "current")
promote_to_silver(stream = "emur", phase = "harmonized")
```

------------------------------------------------------------------------

## Inspection & Auditing

Use these tools to monitor data flow and integrity across the layers.

### Inspect Batch Layer

Lists all ingested batches, their status, file structure, and metadata:

``` r
inspect_batch_layer()
```

### Inspect Bronze Layer

Inspects physical tables, row counts, and the authoritative promotion
log for a given stream:

``` r
inspect_bronze(stream_id = "emur")
```

### Inspect Silver Layer

Checks alignment between phases, table row counts across current and
harmonized schemas, anchor uniqueness, and scans for orphaned secondary
rows:

``` r
inspect_silver(stream_id = "emur")
```
