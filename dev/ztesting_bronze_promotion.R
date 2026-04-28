# ======================================================================= #
# FILE: R/ztesting_bronze_promotion.R
#
# TEMPORARY TEST SCRIPT: Verifies the Bronze Promotion Pipeline
#
# Focus:
# - Append-only promotion semantics
# - Anchor inheritance from main table
# - Bronze metadata enrichment
#
# NOTE:
# - Batch ingestion must already have produced at least one batch
# - This script may be run multiple times safely using dry-run
# ======================================================================= #

# 1. Setup Dev Environment -----------------------------------------------

Sys.setenv(XNE_PEPPER_KEY = "dev_testing_pepper_123")
Sys.setenv(XPIPE_SKIP_HASH_CHECK = "TRUE")

# Assumes working directory is project root
source("R/zload all.R")
source("R/0. batch_materialization.R")
source("R/1. bronze_promotion.R")
source("R/tools_access.R")

# 2. Load Configuration ---------------------------------------------------

.cfg <- load_xpipe_config()

cli::cli_h1("Bronze Promotion Pipeline Test")

# 3. Pre-condition Check --------------------------------------------------

cli::cli_h2("Step 1: Identify Pending Batches")

pending <- .identify_pending_batches(.cfg)

if (nrow(pending) == 0) {
  cli::cli_abort(
    "No pending batches found. Run batch ingestion test first."
  )
}

cli::cli_alert_success(
  "{nrow(pending)} pending batch(es) detected."
)

# 4. Dry Run --------------------------------------------------------------

cli::cli_h2("Step 2: Bronze Promotion Dry Run")

promote_to_bronze(
  config  = .cfg,
  dry_run = FALSE,
  confirm = FALSE
)

cli::cli_alert_success(
  "Dry run completed successfully (no files written)."
)

# 5. Real Promotion -------------------------------------------------------

cli::cli_h2("Step 3: Execute Bronze Promotion")

promote_to_bronze(
  config  = .cfg,
  dry_run = FALSE,
  confirm = FALSE  # disable prompt for test execution
)

cli::cli_alert_success(
  "Bronze promotion completed."
)

# 6. Verification ---------------------------------------------------------

cli::cli_h2("Step 4: Verification")

bronze_root <- .cfg$local$paths$bronze

# Check that Bronze layer exists
if (!fs::dir_exists(bronze_root)) {
  cli::cli_abort("FAILED: Bronze directory not found.")
}

# Inspect one promoted batch
batch <- pending[1, ]
method <- batch$method_id
stream <- batch$stream_id

bronze_ns <- fs::path(bronze_root, paste0(stream, "_", method))

if (!fs::dir_exists(bronze_ns)) {
  cli::cli_abort(
    "FAILED: Bronze namespace {.file {bronze_ns}} not found."
  )
}

year_dirs <- fs::dir_ls(bronze_ns, regexp = "^year=")

cli::cli_alert_info(
  "Bronze partitions discovered: {.val {basename(year_dirs)}}"
)

if (length(year_dirs) == 0) {
  cli::cli_abort("FAILED: No year partitions created.")
}

# Check parquet files and metadata
example_year <- year_dirs[1]
parquet_files <- fs::dir_ls(example_year, glob = "*.parquet")

if (length(parquet_files) == 0) {
  cli::cli_abort("FAILED: No parquet files found in Bronze partition.")
}

cli::cli_alert_success(
  "Bronze parquet files created: {.val {basename(parquet_files)}}"
)

# Load one parquet file and inspect metadata columns
df <- arrow::read_parquet(parquet_files[1])

required_cols <- c(
  "__batch_id",
  "__stream_id",
  "__method_id",
  "__anchor_time",
  "__anchor_year",
  "__anchor_source",
  "__batch_created_at",
  "__ingested_at"
)

missing <- setdiff(required_cols, names(df))

if (length(missing) > 0) {
  cli::cli_abort(
    "FAILED: Missing Bronze metadata columns: {missing}"
  )
}

cli::cli_alert_success(
  "VERIFIED: All required Bronze metadata columns present."
)

# 7. State File Verification ---------------------------------------------

cli::cli_h2("Step 5: Bronze State Verification")

state <- .get_bronze_state(.cfg)

if (!batch$batch_id %in% state$promoted_batches) {
  cli::cli_abort(
    "FAILED: Batch not recorded in Bronze state."
  )
}

cli::cli_alert_success(
  "VERIFIED: Bronze state updated correctly."
)

cli::cli_rule("Bronze Promotion Test Complete")
