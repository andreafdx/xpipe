# ======================================================================= #
# FILE: src/ztesting_batch_ingestion.R
#
# TEMPORARY TEST SCRIPT: Verifies the Batch Ingestion Pipeline
#
# Focus: Preparation context discovery and Materialization to Parquet.
# (Bronze promotion is out of scope for this test)
# ======================================================================= #

# 1. Setup Dev Environment
Sys.setenv(XNE_PEPPER_KEY = "dev_testing_pepper_123")
Sys.setenv(XPIPE_SKIP_HASH_CHECK = "TRUE")

# Assumes working directory is project root ("R projects/xacc")
source("src/zzz.R")
source("src/0. batch_initialization.R")
source("src/1. batch_materialization.R")
# source("src/2. bronze_promotion.R") # Not needed for this test
source("src/tools_access.R")

# 2. Load Configuration
.cfg <- load_xpipe_config()

# Mock XML Extractor for testing
extract_xml <- function(ctx, path) {
  cli::cli_alert_info("MOCK: Extracting XML from {.file {basename(path)}}")
  data.frame(
    id = 1:2,
    source_file = basename(path),
    d_DataDimissione = as.Date("2025-05-20"),
    c_NumeroScheda = c("2001", "2002"),
    c_CodPresidio = "HOSP_TEST",
    c_AzUSSL = "901",
    c_CodicePaziente = "MOCK_CF",
    stringsAsFactors = FALSE
  )
}

# --- Setup Mock SDO Folder ---
sdo_folder_name <- "sdo_2025_xml"
inbox_path <- .cfg$local$paths$inbox
sdo_folder_full <- fs::path(inbox_path, sdo_folder_name)

if (!dir.exists(sdo_folder_full)) {
  fs::dir_create(sdo_folder_full, recurse = TRUE)
}

# Create A, B, C, D dummy files
for (suffix in c("A", "B", "C", "D")) {
  cat("dummy xml", file = fs::path(sdo_folder_full, paste0("fls_", suffix, ".xml")))
}

# --- EXECUTION ---

cli::cli_h1("Batch Ingestion Pipeline Test")

# A. Initialize Multi-File Job
cli::cli_h2("Step 1: Ingestion Preparation")
ctx <- prepare_batch_ingestion(
  filename = sdo_folder_name,
  stream = "sdo",
  method = "xml_campania_2026",
  config = .cfg
)

cli::cli_alert_success("Context prepared for batch: {.val {ctx$batch_id}}")

# B. Materialize Multi-File Batch
cli::cli_h2("Step 2: Materialization")
materialize_batch(ctx, .cfg)

# C. Verify Output
cli::cli_h2("Step 3: Verification")
batch_files <- fs::dir_ls(ctx$batch_dir, glob = "*.parquet")
cli::cli_alert_info("Files discovered in batch folder: {.val {basename(batch_files)}}")

if (length(batch_files) >= 4) {
  cli::cli_alert_success("VERIFIED: Components successfully bundled into the batch.")
} else {
  cli::cli_alert_danger("FAILED: Missing expected parquet files in batch.")
}

meta_file <- fs::path(ctx$batch_dir, "_batch_metadata.json")
if (fs::file_exists(meta_file)) {
  cli::cli_alert_success("VERIFIED: _batch_metadata.json exists.")
} else {
  cli::cli_alert_danger("FAILED: Metadata JSON missing.")
}

cli::cli_rule("Test Complete")
