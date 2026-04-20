# ======================================================================= #
# FILE: src/fnc/development_testing.R
#
# Pipeline Initialization and Run Script
# ======================================================================= #

# Assumes you run this script with the working directory set to the project root ("R projects/xacc")
source("src/fnc/config.R")
source("src/fnc/crypto.R")
source("src/fnc/0. batch_initialization.R")
source("src/fnc/1. batch_materialization.R")

# 2. Load Configuration
.cfg <- load_options()

# 3. Mock Extractor (To simulate Access DB without needing a real file)
extract_access_db <<- function(job, path) {
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
if (!dir.exists("inbox")) dir.create("inbox")
cat("dummy data", file = "inbox/test_sdo_2025.mdb")

# 4. Initialize the pipeline context
my_job <- new_batch_job(
  filename = "test_sdo_2025.mdb",
  method = "sdo_hosp_a",
  alt = FALSE,
  config = .cfg
)
print(.cfg) # Should now trigger the stylish render
print(my_job)

# 5. Pipeline execution (Materialization)
my_job <- materialize_batch_job(my_job, .cfg)
print(my_job)

# Read the generated Parquet to verify
cat("\n--- Resulting Parquet File ---\n")
print(arrow::read_parquet(fs::path(my_job$batch_dir, "data.parquet")))
