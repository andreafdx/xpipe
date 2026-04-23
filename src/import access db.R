
#library(arrow) # Scrittura Parquet
library(cli)

source("src/fnc/access.R")
source("src/fnc/crypto.R")
source("src/fnc/config.R")
source("src/setup.R")


# Setup -------------------------------------------------------------------


cli::cli_h1 ("Script di estrazione da Access MDB")

cli_inform("Input: {mdb_path}
               Output: {out_dir}/{output_name}.parquet")



# Inizializza db ----------------------------------------------------------

# Inizializza connessione al database Access


cli::cli_h2 ("Connessione al database Access")

.db<-.connect_access_db(mdb_path)

.found_tables <- dbListTables(.db)

cli_inform("Connessione al database riuscita. Trovate {length(.found_tables)} tabelle.")



# Estrai le tabelle -------------------------------------------------------


cli::cli_h2 ("Estrazione delle tabelle richieste")
.check_required_tables(.db, .target_tables)

dfs <- .extract_tables(.db, .target_tables)



# Privacy -----------------------------------------------------------------


dfs <- .apply_privacy(dfs, .cfg$runtime$pepper)



# Salvataggio -------------------------------------------------------------


cli::cli_h2("Salvataggio dei data frame e generazione metadati")
saveRDS(dfs, file.path(out_dir, paste0(output_name, ".rds")))
cli::cli_alert_success("Data frame salvati in: {.file {file.path(out_dir, paste0(output_name, '.rds'))}}")


meta <- .generate_meta_json(
  out_dir = out_dir,
  dfs     = dfs,
  extra = list(
    batch_type    = "a",
    source        = mdb_path,
    pseudonymized = TRUE
  )
)


#.generate_meta_file(out_dir, .target_tables, dfs)


.prompt_run_options <- function(cfg) {

  # --- start confirmation --------------------------------------------
  ans <- readline("Start the import? [y/N]: ")
  if (tolower(ans) != "y") {
    cli::cli_abort("Execution aborted by user")
  }

  # --- datastream -----------------------------------------------------
  ds_available <- names(cfg$datastream)
  cat("Available datastreams:\n")
  cat(" -", paste(ds_available, collapse = "\n - "), "\n")

  ds <- readline("Select datastream: ")

  if (!ds %in% ds_available) {
    cli::cli_abort(
      "Invalid datastream {.val {ds}}. Allowed: {paste(ds_available, collapse = ', ')}"
    )
  }

  ds_cfg <- cfg$datastream[[ds]]

  # --- year -----------------------------------------------------------
  year <- readline("Enter year (YYYY): ")

  if (!grepl("^[0-9]{4}$", year)) {
    cli::cli_abort("Invalid year format: {.val {year}}")
  }

  year <- as.integer(year)

  # --- version (only if multiple available) ---------------------------
  version <- NULL

  if (!is.null(ds_cfg$versions) && length(ds_cfg$versions) > 1) {

    cat("Available versions:\n")
    cat(" -", paste(ds_cfg$versions, collapse = "\n - "), "\n")

    version <- readline("Select version: ")

    if (!version %in% ds_cfg$versions) {
      cli::cli_abort(
        "Invalid version {.val {version}}. Allowed: {paste(ds_cfg$versions, collapse = ', ')}"
      )
    }

  } else if (!is.null(ds_cfg$versions)) {
    # single version → auto-select
    version <- ds_cfg$versions[[1]]
  }

  # --- result ---------------------------------------------------------
  result <- list(
    datastream = ds,
    update     = ds_cfg$update,
    year       = year,
    version    = version
  )

  cli::cli_alert_success("Run configuration confirmed")
  cli::cli_alert_info("{result}")
  result
}

.prompt_run_options(.cfg)
