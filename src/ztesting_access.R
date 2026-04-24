# ======================================================================= #
# FILE: src/fnc/access_testing.R
#
# Real-world Test for Access Database Ingestion (2025_full.mdb)
# ======================================================================= #

# 1. Load Core Functions
source("src/core_config.r")
source("src/core_crypto.r")
source("src/tools_access.R")
source("src/0. batch_initialization.R")
source("src/1. batch_materialization.R")
source("src/2. bronze_promotion.R")

# 2. (Removed redundant extractor - now uses official access.R)

# 3. Execution Pipeline
tryCatch({
  cli::cli_h1("Access Data Test: 2025_full.mdb")

  .cfg <- load_xpipe_config()

  my_job <- new_batch_job(
    filename = "2025_full.mdb",
    method   = "quani_mdb",
    stream   = "sdo",
    config   = .cfg
  )
  print(my_job)

  cli::cli_h2("Step 1: Materializing Batch")
  my_job <- materialize_batch_job(my_job, .cfg)

  cli::cli_h2("Step 2: Promoting to Bronze")
  promote_to_bronze(.cfg, stream_id = "sdo")

  cli::cli_h2("Step 3: Verification")
  bronze_path <- fs::path(.cfg$local$paths$bronze, "sdo", "year=2025")
  if (fs::dir_exists(bronze_path)) {
    cli::cli_alert_success("Bronze Year 2025 is ready.")
    cli::cli_inform("Files: {.val {basename(fs::dir_ls(bronze_path))}}")
  }

}, error = function(e) {
  cli::cli_alert_danger("TEST FAILED:")
  print(e)
})
