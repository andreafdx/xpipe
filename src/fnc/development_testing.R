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

extract_access_db <- function(job, path) {
  con <- .connect_access_db(path)
  on.exit(DBI::dbDisconnect(con))
  
  # For now, we only extract the main 'TblScheda' as an example
  # In a full run, this would loop through all required tables
  cli::cli_alert_info("Extracting TblScheda from {.file {path}}")
  df <- DBI::dbReadTable(con, "TblScheda")
  return(df)
}

if (!dir.exists("inbox")) dir.create("inbox")
cat("dummy data", file = "inbox/test_sdo_2025.mdb")

# --- EXECUTION ---

# A. First Ingestion
cli::cli_h2("Act 1: First Ingestion")
mock_batch_version <<- 1
job1 <- new_batch_job(filename = "test_sdo_2025.mdb", method = "sdo_hosp_a", config = .cfg)
materialize_batch_job(job1, .cfg)

# B. Second Ingestion (The Correction)
cli::cli_h2("Act 1: Second Ingestion (Correction)")
Sys.sleep(1.1) # Ensure different timestamp
mock_batch_version <<- 2
job2 <- new_batch_job(filename = "test_sdo_2025.mdb", method = "sdo_hosp_a", config = .cfg)
materialize_batch_job(job2, .cfg)

# C. Promotion to Bronze (The Librarian)
cli::cli_h2("Act 2: Bronze Promotion")
promote_to_bronze(.cfg)

# D. Verification
cli::cli_h2("Verification: The Current Truth")
bronze_2025_file <- fs::path(.cfg$local$paths$bronze, "sdo", "year=2025", "data.parquet")
truth <- arrow::read_parquet(bronze_2025_file)
print(truth)

# Check if 1001 has the new date (2025-03-20)
p1001 <- truth[truth$numero_scheda == "1001", ]
if (nrow(p1001) == 1 && p1001$data_dimissione == as.Date("2025-03-20")) {
  cli::cli_alert_success("VERIFIED: 'Latest Wins' logic correctly applied.")
} else {
  cli::cli_alert_danger("FAILED: 'Latest Wins' logic failed or record duplicated.")
}
