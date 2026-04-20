# ======================================================================= #
# FILE: src/fnc/development_testing.R
#
# Pipeline Initialization and Run Script
# ======================================================================= #

# 1. Setup Dev Environment
Sys.setenv(XNE_PEPPER_KEY = "dev_testing_pepper_123")
Sys.setenv(XACC_SKIP_HASH_CHECK = "TRUE")

# Assumes you run this script with the working directory set to the project root ("R projects/xacc")
source("src/fnc/config.R")
source("src/fnc/crypto.R")
source("src/fnc/0. batch_initialization.R")
source("src/fnc/1. batch_materialization.R")
source("src/fnc/2. bronze_promotion.R")

# 2. Load Configuration
.cfg <- load_options()

# 3. Real Access Extractor (Cross-Platform)
source("src/fnc/access.R")

# Mock XML Extractor for testing
extract_xml <- function(job, path) {
  cli::cli_alert_info("MOCK: Extracting XML from {.file {basename(path)}}")
  data.frame(
    id = 1:2,
    source_file = basename(path),
    data_dimissione = as.Date("2025-05-20"),
    numero_scheda = c("2001", "2002"),
    codice_istituto = "HOSP_TEST",
    cf = "MOCK_CF",
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

cli::cli_h1("Phase 3: Multi-File XML Test")

# A. Initialize Multi-File Job
cli::cli_h2("Act 1: Initialize Multi-File Job")
xml_job <- new_batch_job(
  filename = sdo_folder_name, 
  method = "sdo_campania_xml", 
  config = .cfg
)
print(xml_job)

# B. Materialize Multi-File Batch
cli::cli_h2("Act 1: Materialize Multi-File Batch")
xml_job <- materialize_batch_job(xml_job, .cfg)

# C. Verify Output
cli::cli_h2("Verification: Multi-File Batch Content")
batch_files <- fs::dir_ls(xml_job$batch_dir, glob = "*.parquet")
cli::cli_alert_info("Files in batch: {.val {basename(batch_files)}}")

if (length(batch_files) == 4) {
  cli::cli_alert_success("VERIFIED: All 4 components bundled into the same batch.")
} else {
  cli::cli_alert_danger("FAILED: Missing components in batch.")
}

# D. Promote to Bronze
cli::cli_h2("Act 2: Promote to Bronze")
promote_to_bronze(.cfg, stream_id = "sdo")

# E. Verify Bronze
cli::cli_h2("Verification: Bronze Content")
bronze_stream_dir <- fs::path(.cfg$local$paths$bronze, "sdo")
bronze_tables <- fs::dir_ls(bronze_stream_dir, type = "directory")
cli::cli_alert_info("Bronze tables discovered: {.val {basename(bronze_tables)}}")

for (tbl in bronze_tables) {
  # Direct check for folder existence
  year_folder <- fs::path(tbl, "year=2025")
  if (fs::dir_exists(year_folder)) {
    cli::cli_alert_success("VERIFIED: Table {.val {basename(tbl)}} exists for year 2025.")
  } else {
    cli::cli_alert_danger("FAILED: Table {.val {basename(tbl)}} missing year 2025 folder.")
    cli::cli_inform("Search path: {.file {year_folder}}")
  }
}
