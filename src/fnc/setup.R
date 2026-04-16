# ======================================================================= #
# FILE: src/fnc/setup.R
#
# Pipeline Initialization and Run Script
#
# ======================================================================= #

box::use(
  . / config[load_options, render_config],
  . / batch_import[new_batch_job]
)

# 1. Load configuration and options
source("src/fnc/config.R")
.cfg <- load_options()

# 2. Graceful render
render_config(.cfg)

# 3. Initialize the pipeline context for a specific datastream:
# SDO is yearly, so we omit quarter (it would trigger a warning anyway).
# We also set alt = FALSE as default.
# The internal logic guarantees this matches the YAML definitions safely.
my_job <- new_batch_job(
  filename = "2025_full.mdb",
  datastream = "ps",
  year = 2025,
  q = 5,
  alt = TRUE,
  config = .cfg
)

# 3. Pipeline execution (Coming next!)
# my_job |>
#   extract_raw() |>
#   validate_data() |>
#   save_bronze_layer()
