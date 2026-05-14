---
title: "ADR 010 - Partition column"
category: ADR
author: Andrea Fidecicchi
date:
status:
---

# Partition Column for Domain Time in Bronze Layer

## Context

Partition column in methods.json defines the column in the anchor table
that contains the domain time (e.g., clinical event date) used for
partitioning Bronze data on disk. This column was born when bronze layer
was parquet based and served as a column to partition the parquet
database. In current duckdb design this column is not needed anymore.

## Decision

partition column was kept in mathods.json. While this column is
logically linked to the anchor property in stream (end-start), this
currently has no meaning in bronze materialization and is not considered
from silver onward. In future bronze expansions, this column may reveal
useful to allow retention of most recent data based on year of record.

## Alternatives Considered

Partitioning duckdb database is useless and complicated.

## Consequences

-   No more partitioning in duckdb

-   ability to retain most recent years in bronze based on year of the
    record and not on year of ingestion
