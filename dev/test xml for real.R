# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# dev_test_xml_public.R
# Test multi-component XML ingestion using the official xpipe control plane.
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

# 1. Load Core Functions
source("dev/zload all.R")

tryCatch({
  cli::cli_h1("XML Data Test: Multi-component SDO")

  # Load actual configuration
  .cfg <- load_xpipe_config()

  # For the xml_campania_2026 method, the input is a directory.
  # This folder must exist inside your configured inbox path.
  target_folder <- "xml"

  inbox_path <- fs::path(.cfg$local$paths$inbox, target_folder)
  if (!fs::dir_exists(inbox_path)) {
    cli::cli_abort("Please create folder {.file {inbox_path}} and add your *_A.xml and *_B.xml files inside.")
  }

  # Call the public API
  batch_id <- ingest_batch(
    filename = target_folder,
    method   = "xml_campania_2026",
    stream   = "sdo",
    config   = .cfg,
    confirm  = FALSE # Bypasses the [y/N] prompt for smooth script execution
  )

  # Optional: Immediately inspect the batch layer to confirm the metadata
  print(inspect_batch_layer(.cfg))

}, error = function(e) {
  cli::cli_alert_danger("Pipeline failed!")
  cli::cli_bullets(c("x" = conditionMessage(e)))
})
