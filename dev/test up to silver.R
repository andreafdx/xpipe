source("dev/zload all.R")

load_xpipe_config()

# First ensure the target folder exists

target_folder <- "xml 3-4-1"
.cfg <- get_xpipe_config()
inbox_path <- fs::path(.cfg$local$paths$inbox, target_folder)
if (!fs::dir_exists(inbox_path)) {
  cli::cli_abort("Please create folder {.file {inbox_path}} and add your *_A.xml and *_B.xml files inside.")
}

# Now we start the steps


# Call the public API
ingest_batch(
  filename = target_folder,
  method   = "xml_campania_2026",
  stream   = "sdo"
)

# print(inspect_batch_layer(.cfg))

promote_to_bronze()

.promote_to_silver_current(
  stream_id = "sdo",
  method_id = "xml_campania_2026",
  config    = .cfg
)
