# XACC Healthcare Data Pipeline

## 1. Overview
XACC is a pragmatic, Medallion-based data pipeline designed to ingest healthcare data (SDO, PS, etc.) from proprietary sources and transform it into a materialized "Current Truth" layer for statistical analysis.

## 2. Architecture (The "Local/Remote" Split)
The system is designed to work across distributed SharePoint libraries by separating local configuration from shared data logic.

- **Local (`inst/_xne/local.json`)**: Defines the physical mount points/paths for each layer (Raw, Batch, Bronze).
- **Remote Logic (`data/`)**: Contains the "Shared Brain" of the pipeline:
  - `streams.json`: Defines "What" the data is (Identity keys, Partition rules, Pseudonymization).
  - `methods.json`: Defines "How" to read specific sources (Mappings, Extractor types).
- **Layer Integrity (`data/{layer}/layer.json`)**: Handles security and status for specific data layers.

## 3. Current Achievements (Phase 1)
As of April 2026, the **Ingest & Privacy** phase is complete:

### Features:
- **Contract-Driven Ingest**: Adding new data flows requires only a JSON update.
- **Generic Privacy Engine**: Automatic HMAC-SHA256 hashing and column skipping based on stream rules.
- **Parquet-Native**: Optimized storage for fast R/Python reading.
- **Audit Trails**: Every ingestion creates a timestamped folder with full metadata JSON.

### Core Workflow:
```r
# 1. Load the shared brain and local mounts
cfg <- load_options()

# 2. Initialize a specific job
job <- new_batch_job(filename = "data.mdb", method = "sdo_hosp_a", config = cfg)

# 3. Extract, Pseudonymize, and Save to Parquet
materialize_batch_job(job, cfg)
```

## 4. Roadmap (Phase 2)
The next act is the **Bronze Librarian**:
- **Identity-Based Merge**: Implementing "Latest Wins" logic to resolve corrections.
- **Hive Partitioning**: Physically splitting Bronze data by year to prevent full-history overwrites.
- **DuckDB Engine**: Using a high-performance embedded SQL engine to handle the merge logic safely.
