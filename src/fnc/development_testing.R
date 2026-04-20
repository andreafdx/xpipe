# ======================================================================= #
# FILE: src/fnc/development_testing.R
#
# Comprehensive Phase 1 Pipeline Test Script
# ======================================================================= #

# Setup Environment
Sys.setenv(XNE_PEPPER_KEY = "dev_testing_pepper_123")
Sys.setenv(XACC_SKIP_HASH_CHECK = "TRUE")

# 1. Load Core Functions
# Note: Using source() for direct access to unexported/internal functions during dev
source("R projects/xacc/src/fnc/config.R")
source("R projects/xacc/src/fnc/crypto.R")
source("R projects/xacc/src/fnc/0. batch_initialization.R")
source("R projects/xacc/src/fnc/1. batch_materialization.R")

# 2. Mock Extractor (Simulating an Access DB read)
# In production, these will be real functions in separate files
extract_access_db <<- function(job, path) {
  cli::cli_alert_info("MOCK: Extracting data for method {.val {job$method_id}}")
  data.frame(
    numero_scheda = c("1001", "1002"),
    codice_istituto = c("HOSP01", "HOSP01"),
    cf = c("RSSMRA80A01H501U", "PLTMRA75L41F205K"),
    nome = c("Mario", "Maria"),
    cognome = c("Rossi", "Pilati"),
    data_dimissione = as.Date(c("2025-03-15", "2025-04-20")),
    stringsAsFactors = FALSE
  )
}

# 3. Create dummy file in Inbox if it doesn't exist
inbox_file <- "R projects/xacc/inbox/test_sdo_2025.mdb"
if (!file.exists(inbox_file)) {
  cat("dummy data", file = inbox_file)
}

# 4. Run Test Suite
tryCatch({
  # Ensure we are in project root for path resolution
  setwd("R projects/xacc")
  
  cli::cli_h1("XACC Development Test")

  # A. Load Configuration
  cli::cli_h2("Step A: Configuration Loading")
  cfg <- load_options()
  print(cfg)

  # B. Initialize Batch Job
  cli::cli_h2("Step B: Batch Job Initialization")
  job <- new_batch_job(
    filename = "test_sdo_2025.mdb",
    method = "sdo_hosp_a",
    config = cfg,
    alt = FALSE
  )
  print(job)

  # C. Materialize Batch
  cli::cli_h2("Step C: Materialization & Privacy")
  job <- materialize_batch_job(job, cfg)
  print(job)

  # D. Verify Physical Output
  cli::cli_h2("Step D: Physical Output Verification")
  parquet_file <- fs::path(job$batch_dir, "data.parquet")
  
  if (fs::file_exists(parquet_file)) {
    cli::cli_alert_success("Parquet file created at: {.file {parquet_file}}")
    
    # Check data content
    df <- arrow::read_parquet(parquet_file)
    cli::cli_alert_info("Columns in materialized batch: {.val {names(df)}}")
    
    if (!"nome" %in% names(df) && nchar(df$cf[1]) == 64) {
      cli::cli_alert_success("VERIFIED: Privacy rules (hashing & skipping) applied correctly.")
    } else {
      cli::cli_alert_danger("FAILED: Privacy rules not applied correctly.")
    }
    
    print(head(df))
  } else {
    cli::cli_alert_danger("FAILED: Parquet file not found.")
  }

  cli::cli_rule("Test Complete")

}, error = function(e) {
  cli::cli_alert_danger("CRITICAL ERROR during testing:")
  print(e)
})
