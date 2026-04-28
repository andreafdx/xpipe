# ======================================================================= #
# FILE: R/access_testing.R
#
# Real-world Test for Access Database Ingestion (2025_full.mdb)
# ======================================================================= #

# 1. Load Core Functions
source("R/zload all.R")

# 2. (Removed redundant extractor - now uses official access.R)

# 3. Execution Pipeline
tryCatch({
  cli::cli_h1("Access Data Test: 2025_full.mdb")

  .cfg <- load_xpipe_config()

  cli::cli_h2("Step 1 & 2: Ingesting Batch")
  batch_id <- ingest_batch(
    filename = "2025_full.mdb",
    method   = "quani_mdb",
    stream   = "sdo",
    config   = .cfg
  )
  cli::cli_alert_success("Batch materialized: {.val {batch_id}}")

  promote_to_bronze (
    config = .cfg
)
}, error = function(e) {
  cli::cli_alert_danger("TEST FAILED:")
  print(e)
})
