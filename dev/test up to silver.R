source("dev/zload all.R")

load_xpipe_config(
  project_root = "C:/Users/78299/OneDrive - A.O.R.N. Antonio Cardarelli/EpiLab - Code/XNE"
)

# First ensure the target folder exists

target_folder <- "giugno"
.cfg <- get_xpipe_config()
inbox_path <- fs::path(.cfg$xne$paths$inbox, target_folder)
if (!fs::dir_exists(inbox_path)) {
  cli::cli_abort(
    "Please create folder {.file {inbox_path}} and add your *_A.xml and *_B.xml files inside."
  )
}

# Now we start the steps

# Call the public API
ingest_batch(
  filename = target_folder,
  method = "xml_emur_campania_2026",
  stream = "emur"
)


# print(inspect_batch_layer(.cfg))

promote_to_bronze()

promote_to_silver(phase = "all", stream = "emur")
