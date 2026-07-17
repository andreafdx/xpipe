---
title: "Error Class Taxonomy"
output: html_document
editor_options:
  markdown:
    wrap: 72
---

# Error Class Taxonomy

## Overview

All xpipe errors are structured R conditions thrown via `cli::cli_abort`.
Every error carries a vector of S3 classes following a three-level
hierarchy:

```
c("<leaf_class>", "<domain_class>", "xpipe_error")
```

Some errors additionally carry a domain-intermediate class:

```
c("<leaf_class>", "<domain_class>", "<group_class>", "xpipe_error")
```

This allows callers to catch errors at any level of specificity using
`rlang::try_fetch` or `tryCatch`:

```r
# Catch any xpipe error
rlang::try_fetch(expr, xpipe_error = function(e) ...)

# Catch only batch-layer errors
rlang::try_fetch(expr, xpipe_batch_error = function(e) ...)

# Catch a specific condition
rlang::try_fetch(expr, xpipe_batch_collision = function(e) ...)
```

---

## Full Taxonomy

```
xpipe_error                            # root — catch-all for the package
│
├── xpipe_runtime_error
│   └── xpipe_runtime_pepper           # XNE_PEPPER_KEY missing or empty at startup
│
├── xpipe_config_error
│   ├── xpipe_config_missing           # load_xpipe_config() not yet called
│   └── xpipe_config_schema_domain     # method references a stream with a different schema_domain
│
├── xpipe_local_error
│   └── xpipe_local_paths              # required path in xne.json is missing or does not exist on disk
│
├── xpipe_streams_error
│   ├── xpipe_streams_metadata         # _meta block missing, wrong type, or version absent
│   └── xpipe_streams_definition       # stream entry missing required fields or declares invalid anchor
│
├── xpipe_methods_error                # methods.json failed to load or validate
│
├── xpipe_json_error                   # (base class; typically composed into domain errors)
│   ├── xpipe_json_not_found           # JSON file does not exist on disk
│   ├── xpipe_json_schema              # JSON file fails AJV schema validation
│   └── xpipe_json_invalid             # JSON file exists but is not parseable
│
├── xpipe_asset_error
│   └── xpipe_asset_not_found          # internal inst/ asset cannot be located
│
├── xpipe_batch_error                  # batch-layer errors from 0_batch_materialization.R and core_config.R
│   ├── xpipe_batch_config             # xpipe_config is missing required branches (paths, streams, methods)
│   ├── xpipe_batch_schema_domain      # method and stream schema_domain mismatch
│   ├── xpipe_batch_method             # unknown or invalid method identifier
│   ├── xpipe_batch_stream             # unknown stream identifier
│   ├── xpipe_batch_path               # input filename not found in inbox
│   ├── xpipe_batch_paths              # batch layer directory missing or not configured
│   ├── xpipe_batch_input_type         # method requires file but directory provided, or vice versa
│   ├── xpipe_batch_input_files        # input files pattern resolving failed (missing or ambiguous files)
│   ├── xpipe_batch_id                 # explicit batch_id is invalid (e.g. empty string)
│   ├── xpipe_batch_collision          # target batch directory already exists (append-only guard)
│   ├── xpipe_batch_input              # input file missing or empty at materialization time
│   ├── xpipe_batch_instrument         # no extractor registered for method type, or function not loaded
│   ├── xpipe_batch_extraction         # extractor failed or returned an invalid / empty result
│   ├── xpipe_batch_materialization    # persistence phase failed (Parquet write or non-data.frame element)
│   │   └── xpipe_batch_type_enforcement # column type enforcement failed or is unsafe (e.g. numeric to character coercion)
│   ├── xpipe_batch_abort              # user declined confirmation prompt
│   ├── xpipe_batch_metadata           # layer.json missing, invalid format, or failed to read/write during promotion
│   ├── xpipe_batch_hash               # Batch layer integrity hash check failed
│   └── xpipe_privacy                  # PHI hashing / pseudonymization error or invalid shape
│
├── xpipe_bronze_error                 # bronze-layer errors from 1_bronze_promotion.R
│   ├── xpipe_bronze_state             # layer.json missing, invalid format, or failed to write
│   ├── xpipe_bronze_anchor            # anchor table / column / key definition or join failure
│   ├── xpipe_bronze_partition         # unsupported partition granularity declared by stream
│   ├── xpipe_bronze_append_only       # Bronze shard already exists — refusing to overwrite
│   └── xpipe_bronze_abort             # user declined Bronze promotion confirmation prompt
│
└── xpipe_silver_error                 # silver-layer errors from 2_silver_promotion.R
    ├── xpipe_silver_config            # silver.json missing, disabled, or invalid configuration
    ├── xpipe_silver_state             # Silver DB path or log validation failure
    ├── xpipe_silver_anchor            # Silver anchor table missing from Bronze
    └── xpipe_silver_abort             # user declined Silver promotion confirmation prompt
```

---

## Notes on Class Composition

### JSON errors carry a domain prefix

`xpipe_json_*` classes are not thrown standalone. They are combined
with a caller-supplied `error_class` argument in `.validate_json_schema`
and `.read_json_safe`:

```r
# Example: methods.json schema failure
class = c("xpipe_methods_error", "xpipe_json_schema", "xpipe_json_error", "xpipe_error")
```

This means a schema validation error for `streams.json` carries both
`xpipe_streams_error` (domain) and `xpipe_json_schema` (mechanism),
allowing either level to be caught independently.

### `xpipe_batch_error` appears in two files

The class `xpipe_batch_error` is used by both `0_batch_materialization.R`
(for ingestion-level errors) and `core_config.R` (for batch-layer state
errors like a missing or invalid `layer.json`). This is intentional —
they are all errors originating from or describing the Batch layer.

### `try_fetch` wrapping in materialization

The extraction and persistence phases in `.materialize_batch` are
wrapped with `rlang::try_fetch`. This means that errors from external
instruments (e.g. ODBC failures, XML parse errors) are caught and
re-thrown as domain-class errors:

- Extraction instrument failures → `xpipe_batch_extraction`
- Filesystem write failures → `xpipe_batch_materialization`

The original error is preserved as the `parent` condition and is
visible in the traceback as "Caused by".

---

## Catching Errors in Practice

```r
# Catch only user-aborted operations (non-fatal, can be ignored in scripts)
rlang::try_fetch(
  promote_to_bronze(config),
  xpipe_bronze_abort = function(e) {
    cli::cli_inform("Promotion cancelled.")
    invisible(NULL)
  }
)

# Catch any configuration problem and re-surface cleanly
rlang::try_fetch(
  load_xpipe_config(),
  xpipe_config_error = function(e) {
    cli::cli_abort("Pipeline not ready: check configuration.", parent = e)
  }
)

# Catch everything from the package
rlang::try_fetch(
  ingest_batch(filename, stream, method),
  xpipe_error = function(e) {
    log_error(conditionMessage(e))
    stop(e)
  }
)
```
