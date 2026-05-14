# ADR-008: Silver Compute and Storage Engine

**Date**: 2026-05-06
**Status**: Accepted
**Decider**: Andrea Fidecicchi

## Context

Silver-current must perform identity resolution and "latest wins"
version selection over the Bronze layer. For high-volume streams like
"File C" (5M+ rows/year), this involves processing 25M+ rows for a
3-year window. The computation requires:

1. Efficiently reading millions of rows from Bronze.
2. Grouping by `identity_keys`.
3. Applying window functions (e.g., `row_number()`) to select the most
   recent record per entity.

## Decision

Use **DuckDB** as both the compute engine and the storage format for the
Silver layer.

- **Storage**: Silver is stored in DuckDB native files (`.duckdb`), one per
  stream. Each file contains multiple tables (e.g., `current`, `harmonized`).
- **Compute**: Transformation logic is expressed in DuckDB SQL, executing
  directly over the Bronze DuckDB files.
- **Window**: A sliding window of the latest 2-3 years is typically used
  for active analysis, though full-history rebuilds are supported.

## Alternatives Considered

- **Arrow Dataset + dplyr**: A strong contender that avoids new
  dependencies, but lacks the native window function performance of
  DuckDB and would struggle with memory limits at the projected 25M+ row
  scale.
- **Parquet for Silver storage**: Offers universal interoperability, but
  since all analysis currently happens in R (using either `arrow` or
  `duckdb` packages), the native DuckDB format provides better query
  performance and the ability to bundle multiple related tables in one
  file.

## Consequences

- **Performance**: Vectorized SQL window functions provide sub-second
  identity resolution even for the multi-million row File C stream.
- **Dependency**: The `duckdb` package is now a core requirement for
  both the Silver and Bronze layers.
- **Analytical Power**: Users can query Silver using either `dplyr`
  (via `dbplyr`) or raw SQL, providing maximum flexibility for complex
  epidemiological questions.
- **Exportability**: If data needs to be shared with Python or BI tools,
  DuckDB can export any Silver table to Parquet with a single `COPY` command.

