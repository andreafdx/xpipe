# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# dev_test_xml_public.R
# Test multi-component XML ingestion using the official xpipe control plane.
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

source("dev/zload all.R")
.cfg <- load_xpipe_config()
# For the xml_campania_2026 method, the input is a directory.
# This folder must exist inside your configured inbox path.
target_folder <- "xml"

inbox_path <- fs::path(.cfg$xne$paths$inbox, target_folder)
if (!fs::dir_exists(inbox_path)) {
  cli::cli_abort(
    "Please create folder {.file {inbox_path}} and add your *_A.xml and *_B.xml files inside."
  )
}

# Call the public API
batch_id <- ingest_batch(
  filename = target_folder,
  method = "xml_campania_2026",
  stream = "sdo",
  config = .cfg,
  confirm = FALSE # Bypasses the [y/N] prompt for smooth script execution
)

# Optional: Immediately inspect the batch layer to confirm the metadata
print(inspect_batch_layer(.cfg))
